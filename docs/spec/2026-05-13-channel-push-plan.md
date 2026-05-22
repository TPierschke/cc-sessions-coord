# Umsetzungsplan — Channel-Push v2.1.80+ (v2)

Status: DRAFT v2 (2026-05-13, nach Plan-Council-Runde 1)
Basis: Spec v4 (4× PASS), eigenes Council-Verdikt R1 4×NEEDS-REVISION.

Adressierte R1-Punkte:
- DB-Dialekt explizit Postgres (event_seq IDENTITY + TIMESTAMPTZ sind Postgres-spezifisch).
- Reihenfolge umgestellt: P4 Token-Datei VOR P3 Channel-Endpoints (Auth-Fundament zuerst).
- ACK-SQL Reconnect-Bug behoben: push_connection_id NICHT im WHERE; nur fuer Watchdog.
- Watchdog als `BackgroundService`, nicht `Task.Delay`.
- SSE-Header explizit dokumentiert.
- Token-Autogen: nur wenn Datei fehlt — Worker-Restart invalidiert KEINE bestehende.
- wmic → primaer `Get-CimInstance`, wmic nur Fallback.
- Akzeptanz-Stub-Gates pro Phase ausgebaut.

## Reihenfolge (neu)

```
P1: DB-Migration ──► P2: by-pid Endpoint + Hook ──► P3: Token-Datei + Auto-Gen
                                                          │
                                                          ▼
                                                    P4: Channel-Endpoints (Stream + ACK + Watchdog-BackgroundService)
                                                          │
                                                          ▼
                                                    P5: Rotate-Token-Endpoint
                                                          │
                                                          ▼
                                                    P6: Bridge (Node)
                                                          │
                                                          ▼
                                                    P7: install-service.ps1 (LocalService + ACL)
                                                          │
                                                          ▼
                                                    P8: Smoke-Tests A1-A14
                                                          │
                                                          ▼
                                                    P9: ~/.claude.json Integration
```

---

## DB-Vorgabe

**Postgres only.** Wir nutzen kein SQL Server, kein SQLite. Migration-Snippets nutzen Postgres-Syntax (`BIGINT GENERATED ALWAYS AS IDENTITY`, `TIMESTAMPTZ`, `UUID`).

---

## P1 — DB-Migration

**Ziel**: Schema-Erweiterungen, idempotent, rollback-faehig.

**Tasks**
1. `src/CcSessionsCoord.Worker/Migrations/2026-05-13-channel-push.sql`:
   ```sql
   -- forward
   ALTER TABLE coord.injections ADD COLUMN IF NOT EXISTS event_seq BIGINT GENERATED ALWAYS AS IDENTITY;
   ALTER TABLE coord.injections ADD COLUMN IF NOT EXISTS last_pushed_at TIMESTAMPTZ NULL;
   ALTER TABLE coord.injections ADD COLUMN IF NOT EXISTS push_connection_id UUID NULL;
   ALTER TABLE coord.injections ADD COLUMN IF NOT EXISTS delivered_via TEXT NULL;
   ALTER TABLE coord.injections ADD COLUMN IF NOT EXISTS push_attempts INT NOT NULL DEFAULT 0;
   CREATE INDEX IF NOT EXISTS injections_event_seq_idx ON coord.injections(event_seq);
   CREATE INDEX IF NOT EXISTS injections_pending_target_idx
       ON coord.injections(target_session_id, expires_at)
       WHERE delivered_at IS NULL AND cancelled_at IS NULL;
   ALTER TABLE coord.sessions ADD COLUMN IF NOT EXISTS pid_start_time BIGINT NULL;
   ```
2. **Rollback** (separate Datei):
   ```sql
   DROP INDEX IF EXISTS coord.injections_pending_target_idx;
   DROP INDEX IF EXISTS coord.injections_event_seq_idx;
   ALTER TABLE coord.injections DROP COLUMN IF EXISTS push_attempts;
   ALTER TABLE coord.injections DROP COLUMN IF EXISTS delivered_via;
   ALTER TABLE coord.injections DROP COLUMN IF EXISTS push_connection_id;
   ALTER TABLE coord.injections DROP COLUMN IF EXISTS last_pushed_at;
   ALTER TABLE coord.injections DROP COLUMN IF EXISTS event_seq;
   ALTER TABLE coord.sessions DROP COLUMN IF EXISTS pid_start_time;
   ```
3. **Backup-Schritt vor Migration**: in `apply-update.ps1` ergaenzen:
   `pg_dump --schema-only --schema=coord ... > C:\ProgramData\CcSessionsCoord\backups\coord-schema-$(date).sql`
4. Migration via bestehenden Migrations-Runner im Worker (oder manuell via psql in apply-update.ps1).

**Akzeptanz-Gate P1** (alle muessen gruen sein bevor P2 startet):
- `psql -c "\d coord.injections"` listet `event_seq`, `last_pushed_at`, `push_connection_id`, `delivered_via`.
- `psql -c "\d coord.sessions"` listet `pid_start_time`.
- `psql -c "\di coord.injections*"` listet beide neuen Indexe.
- `INSERT INTO coord.injections (...) RETURNING event_seq` liefert eine monotone Zahl.
- Rollback-Script laeuft ohne Fehler durch (in Testumgebung).

---

## P2 — `/coord/sessions/by-pid` + Hook erweitern

**Ziel**: Worker kann pid+pid_start_time-Match liefern; Hook sendet pid_start_time.

**Tasks**
1. **Repository**:
   - `CoordRepository.cs::FindSessionByPidAsync(long pid, long pidStartTimeMs)`:
     ```sql
     SELECT * FROM coord.sessions
      WHERE pid = @pid AND pid_start_time IS NOT NULL
        AND ABS(pid_start_time - @pid_start_time) < 100
      ORDER BY last_heartbeat DESC LIMIT 1;
     ```
2. **Endpoint** in `CoordEndpoints.cs`:
   ```csharp
   app.MapGet("/coord/sessions/by-pid", async ([FromQuery] long pid, [FromQuery] long pid_start_time, HttpContext ctx, ICoordRepository repo, IChannelTokenStore tokens) => {
       var ok = await tokens.ValidateAsync(ctx.Request.Headers["X-Coord-Channel-Token"]);
       if (!ok) return Results.Unauthorized();
       var s = await repo.FindSessionByPidAsync(pid, pid_start_time);
       return s is null ? Results.NotFound() : Results.Ok(new { session_id = s.SessionId, started_at = s.StartedAt });
   });
   ```
3. **Hook**: `~/.claude/scripts/session-coord/db.ps1::Update-SessionHeartbeat` erweitern:
   ```powershell
   $resolvedPid = Get-ClaudeCodePid
   $proc = Get-Process -Id $resolvedPid -ErrorAction SilentlyContinue
   $startMs = if ($proc) { [DateTimeOffset]::new($proc.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds() } else { $null }
   # POST-Body um pid_start_time erweitern
   ```
4. **Worker Heartbeat-Endpoint** (existiert): nimmt `pid_start_time` entgegen, schreibt in DB.

**Akzeptanz-Gate P2**:
- Hook laeuft, sendet pid+pid_start_time.
- `SELECT pid_start_time FROM coord.sessions WHERE session_id = '<my>'` liefert non-null nach naechstem Heartbeat.
- `Invoke-RestMethod /coord/sessions/by-pid?pid=X&pid_start_time=Y -Headers @{"X-Coord-Channel-Token"="<token>"}` → 200 + session_id.
- Falscher pid_start_time (z.B. +200ms) → 404.
- Ohne Token-Header → 401.

---

## P3 — Token-Datei + Auto-Gen-Strategie

**Ziel**: Channel-Token bootstrap, ohne dass Worker-Restart Bridges invalidiert.

**Tasks**
1. **Pfad**: `C:\ProgramData\CcSessionsCoord\channel-token.txt`.
2. `IChannelTokenStore` Singleton mit:
   - `EnsureExists()` — bei Worker-Startup: **wenn Datei existiert + non-empty, nichts tun**. Sonst generiere `Guid.NewGuid().ToString("N")`, schreibe atomic (tmp+`File.Move`).
   - `GetCurrentTokenHash()` — caches SHA256, re-cache bei FileChanged-Watcher.
   - `ValidateAsync(string header)` — FixedTimeEquals gegen Hash.
   - `RotateAsync()` — generiere neu, atomic write, invalidate cache, return new token.
3. **ACL setzen** via `icacls` (Aufruf nur wenn Datei neu erzeugt):
   - Wenn `Process.Start("icacls.exe", ...)` fehlschlaegt: stderr-Warning, weitermachen (ACL bleibt erbschaftsgesetzt — User muss manuell fixen).

**Akzeptanz-Gate P3**:
- Worker-Startup mit nicht-vorhandener Datei → Datei wird erzeugt, GUID, ACL korrekt (`icacls /verbose <path>`).
- Worker-Restart bei vorhandener Datei → Datei BLEIBT, gleicher Inhalt (verifiziert via Hash vor/nach Restart).
- `IChannelTokenStore.ValidateAsync` mit korrektem Token → true; mit falschem → false.

---

## P4 — Channel-Endpoints (Stream + ACK + Watchdog)

**Ziel**: SSE-Push und ACK-Endpoint, mit Connection-Registry und Watchdog-BackgroundService.

**Tasks**
1. **`IChannelConnectionRegistry`** Singleton:
   - State pro Session:
     ```csharp
     class ActiveConnection {
       Guid ConnectionId;
       DateTime ConnectedAtUtc;
       string TokenHashHex;
       long BridgeEpochAdvertised;
       long LastEventSeq;
       HttpResponse Response;
       CancellationToken RequestAborted;
     }
     ```
   - State pro Session-Eviction:
     ```csharp
     class EvictionState {
       DateTime LastEvictionAtUtc;
       DateTime EvictionLockUntilUtc;
       DateTime BypassCoolDownUntilUtc; // gesetzt bei Token-Rotation
     }
     ```
   - Methods:
     - `TryConnect(sessionId, tokenHash, bridgeEpoch, response, lastEventId, requestAborted, out Guid connectionId, out string status)` mit per-session-Lock.
       - Status: `"ok"` | `"409-cooldown"` | `"409-conflict"`.
     - `Remove(sessionId, connectionId)`.
     - `GetActive(sessionId) → ActiveConnection?`.
     - `EvictAll(sessionId, reason)` — fuer Rotation.
     - `SetBypassCoolDown(sessionId, duration)`.
2. **`/coord/channel/stream`** Endpoint:
   ```csharp
   app.MapGet("/coord/channel/stream", async (HttpContext ctx, IChannelTokenStore tokens, IChannelConnectionRegistry reg, ICoordRepository repo, IRateLimitGuard rate) => {
       // 1. Token via Header validieren
       var token = ctx.Request.Headers["X-Coord-Channel-Token"].FirstOrDefault();
       if (!await tokens.ValidateAsync(token)) return Results.Unauthorized();
       // 2. Query-Param-Token explizit ablehnen
       if (ctx.Request.Query.ContainsKey("token")) return Results.BadRequest(new { error="token-must-be-header" });
       // 3. Rate-Limit pro Token-Hash
       var hash = Sha256(token);
       if (!rate.TryAcquire("channel-stream-" + hash, max:10, window:TimeSpan.FromMinutes(1)))
           return Results.StatusCode(429);
       // 4. SessionId + BridgeEpoch + LastEventId aus Header
       var sessionId = ctx.Request.Headers["X-Coord-Session-Id"].FirstOrDefault();
       var bridgeEpoch = long.Parse(ctx.Request.Headers["X-Coord-Bridge-Epoch"].FirstOrDefault() ?? "0");
       var lastEventId = long.Parse(ctx.Request.Headers["Last-Event-ID"].FirstOrDefault() ?? "0");
       // 5. SSE-Header
       ctx.Response.Headers["Content-Type"] = "text/event-stream";
       ctx.Response.Headers["Cache-Control"] = "no-cache";
       ctx.Response.Headers["X-Accel-Buffering"] = "no";
       await ctx.Response.Body.FlushAsync();
       // 6. Connection registrieren
       if (!reg.TryConnect(sessionId, hash, bridgeEpoch, ctx.Response, lastEventId, ctx.RequestAborted, out var connId, out var status)) {
           if (status.StartsWith("409")) return Results.Conflict(new { error=status });
       }
       // 7. event:hello
       await WriteFrame(ctx.Response, "hello", $"{{\"connection_id\":\"{connId}\",\"server_time\":\"{DateTime.UtcNow:o}\"}}", null);
       // 8. Replay pending
       var pending = await repo.GetPendingForReplayAsync(sessionId, lastEventId);
       foreach (var inj in pending) {
           await WriteFrame(ctx.Response, "inject", JsonSerializer.Serialize(InjectPayload(inj)), inj.EventSeq);
           // last_pushed_at + push_connection_id update
           await repo.MarkPushedAsync(inj.Id, connId);
       }
       // 9. Loop: 5s ping + on-demand via Channel<Injection>
       try {
           while (!ctx.RequestAborted.IsCancellationRequested) {
               var inject = await PullNextOrTimeout(connId, TimeSpan.FromSeconds(5), ctx.RequestAborted);
               if (inject == null) {
                   await WriteFrame(ctx.Response, "ping", "{}", null);
               } else {
                   await WriteFrame(ctx.Response, "inject", JsonSerializer.Serialize(InjectPayload(inject)), inject.EventSeq);
                   await repo.MarkPushedAsync(inject.Id, connId);
               }
           }
       } finally {
           reg.Remove(sessionId, connId);
       }
       return Results.Empty;
   });
   ```
3. **`/coord/channel/ack`** Endpoint:
   ```csharp
   app.MapPost("/coord/channel/ack", async (HttpContext ctx, IChannelTokenStore tokens, IChannelConnectionRegistry reg, ICoordRepository repo) => {
       if (!await tokens.ValidateAsync(ctx.Request.Headers["X-Coord-Channel-Token"])) return Results.Unauthorized();
       var sessionId = ctx.Request.Headers["X-Coord-Session-Id"].FirstOrDefault();
       var active = reg.GetActive(sessionId);
       if (active == null) return Results.StatusCode(403);
       var body = await JsonSerializer.DeserializeAsync<AckBody>(ctx.Request.Body);
       // KEIN push_connection_id-Match — das wuerde Reconnect-Acks blockieren.
       // Wir validieren nur: aktive Connection existiert + connection_id == aktuelles connection_id + injection.target_session_id == sessionId.
       if (body.ConnectionId != active.ConnectionId) return Results.StatusCode(403);
       var updated = await repo.MarkDeliveredAsync(body.InjectionId, sessionId);
       return Results.Ok(new { acked = updated > 0 ? "set" : "idempotent" });
   });
   ```
4. **`InjectionPublisher`** Service (Singleton):
   - Method `Publish(CoordInjection)` — sucht aktive Connection via Registry, schreibt in per-Connection-`Channel<CoordInjection>` (System.Threading.Channels), Stream-Loop pickt es auf.
   - Wird aufgerufen von `/coord/injections` POST-Handler nach DB-INSERT.
5. **Watchdog als `BackgroundService`** mit Push-Counter:
   - DB-Spalte zusaetzlich: `push_attempts INT NOT NULL DEFAULT 0` (siehe P1, dort ergaenzen).
   - `WatchdogService : BackgroundService` — alle 1 sec:
     ```sql
     SELECT id, target_session_id, push_connection_id FROM coord.injections
      WHERE delivered_at IS NULL AND cancelled_at IS NULL
        AND last_pushed_at IS NOT NULL
        AND last_pushed_at < now() - INTERVAL '7 seconds'
        AND push_attempts < 2
        AND expires_at > now();
     ```
   - Fuer jede Zeile:
     - Pruefe ob aktive Connection fuer `target_session_id` existiert UND `connection.ConnectionId == row.push_connection_id`. Wenn ja → Republish (`UPDATE ... SET last_pushed_at = now(), push_attempts = push_attempts + 1`).
     - Wenn nein → setze `push_attempts = 2` (markiert als "Worker gibt auf"), Pull-Pfad uebernimmt.
   - **Pagination-Cursor-Vertrag (explizit)**: Worker holt Replay in einer Schleife `while rows.Count == 200 { lastSeq = rows.Last().EventSeq; rows = SELECT ... WHERE event_seq > lastSeq LIMIT 200; }` — drain bis vollstaendig leer ODER Connection-Abort. Kein impliziter "naechster Reconnect macht den Rest", sondern aktiv in einer Connection durchziehen.
   - **Gap-Policy**: sichtbare Sequenzluecken (durch `cancelled_at NOT NULL`, `expires_at < now()`, oder `delivered_at NOT NULL` Filter) sind **erwartet**, kein Incident, kein Logging-Alarm. Bridge ignoriert Sprung-Lücken in `event_seq`.
   - **`delivered_at`-Semantik (klargestellt)**: wird **ausschliesslich nach persistiertem ACK** vom `/coord/channel/ack`-Endpoint gesetzt — NIE beim SSE-Send-Zeitpunkt. Damit ist `delivered_at IS NULL` der einzige relevante Filter fuer "noch zu liefern".
   - **push_attempts-Reset-Policy**: `push_attempts` wird **nie zurueckgesetzt** im Lebenszyklus einer Injection. Nach `push_attempts >= 2` ist die Injection fuer den Push-Pfad endgueltig "abgegeben". Damit kein Resend-Loop bei flappy Bridge, Pull-Hook uebernimmt Verantwortung.
   - **Lost-Message-Garantie**: nach `push_attempts >= 2 OR last_pushed_at < now()-15s` ist die Injection fuer den Push-Pfad tot — der Pull-Hook holt sie beim naechsten UserPromptSubmit (Standard-Polling-Intervall). Das ist die einzige Lost-Message-Mitigation und sie ist bewusst.

**SSE-Wire-Format (klargestellt fuer ASP.NET Core)**:
```csharp
async Task WriteFrame(HttpResponse r, string evt, string data, long? id) {
    if (id.HasValue) await r.WriteAsync($"id: {id.Value}\n");
    await r.WriteAsync($"event: {evt}\n");
    await r.WriteAsync($"data: {data}\n\n");
    await r.Body.FlushAsync();
}
```

**Akzeptanz-Gate P4**:
- `curl -N -H "X-Coord-Channel-Token: <t>" -H "X-Coord-Session-Id: <s>" http://127.0.0.1:7733/coord/channel/stream` zeigt sofort `event: hello` + `event: ping` alle 5s.
- INSERT in coord.injections + Publisher-Call → `event: inject` Frame in <500ms.
- POST `/coord/channel/ack` mit korrekter connection_id → DB `delivered_at` gesetzt.
- ACK ohne aktive Connection → 403.
- ACK mit falscher connection_id (anderer aktiver SSE) → 403.
- Watchdog: kill Bridge nach event:inject (vor ACK) → nach 7s `last_pushed_at < now-7s` → Republish (wenn Connection nochmal hochgekommen) ODER kein Resend bei nicht mehr aktiver Connection → Pull-Hook uebernimmt.

---

## P5 — Rotate-Token-Endpoint

**Ziel**: Token rotation via Admin-Endpoint.

**Tasks**
1. `AdminEndpoints.cs::MapAdminEndpoints` erweitern:
   ```csharp
   app.MapPost("/coord/admin/rotate-channel-token", async (HttpContext ctx, IAdminTokenStore admin, IChannelTokenStore channel, IChannelConnectionRegistry reg) => {
       if (!await admin.Validate(ctx.Request.Headers["X-Admin-Token"])) return Results.Unauthorized();
       var newToken = await channel.RotateAsync();
       var count = reg.EvictAll(reason: "token-rotated", bypassCoolDownFor: TimeSpan.FromSeconds(5));
       return Results.Ok(new { rotated_at = DateTime.UtcNow, evicted = count });
   });
   ```
2. `EvictAll` sendet `event: token-rotated` + `event: bye {reason:"rotated"}` an alle Connections, schliesst Streams (via `CancellationTokenSource.Cancel`), setzt `BypassCoolDownUntilUtc = now + 5s`.

**Akzeptanz-Gate P5**:
- Bridge online → `POST /coord/admin/rotate-channel-token` → Bridge erhaelt `token-rotated`, schliesst, reconnectet mit neuem Token ≤ 5s.

---

## P6 — Bridge (Node)

**Ziel**: Robuste stdio-MCP-Bridge.

**Tasks**
1. Verzeichnis `src/CcSessionsCoord.ChannelBridge/`:
   - `package.json` mit `"type":"module"`, deps `@modelcontextprotocol/sdk`, `eventsource`, `undici`.
   - `tsconfig.json` (target ES2022, module ESNext).
   - `src/index.ts` — entry, MCP-Server starten, async-init triggern.
   - `src/lifecycle.ts` — token-load → pid-resolve → session-resolve → SSE-connect.
   - `src/pid-utils.ts` — `Get-CimInstance` via PowerShell-Spawn (primaer), `wmic` fallback. Returns `{ parentPid, creationDateMs }`.
   - `src/sse-client.ts` — EventSource-Wrapper mit Reconnect-Backoff [1,2,4,4,4,...]s + Last-Event-ID, Header-Auth.
   - `src/dedupe.ts` — atomic write/read seen.json, Korruptions-Recovery.
   - `src/mcp-server.ts` — `Server`-Instanz aus sdk, sendNotification("notifications/claude/channel", params).
2. **Event-Loop**:
   ```ts
   sse.on('event', (e) => {
     switch(e.type) {
       case 'hello': state.connectionId = JSON.parse(e.data).connection_id; break;
       case 'inject':
         const inj = JSON.parse(e.data);
         if (!validate(inj)) { log.err('invalid'); return; }
         if (dedupe.has(inj.injection_id, 1*60*60*1000)) { ack(inj.injection_id); return; }
         await mcp.notification('notifications/claude/channel', inj);
         dedupe.add(inj.injection_id, parseInt(e.id));
         ack(inj.injection_id);
         break;
       case 'ping': break;
       case 'token-rotated': state.tokenRotationInProgress = true; break;
       case 'bye': sse.close(); jitterAndReconnect(); break;
       case 'evicted': log.err('evicted'); process.exit(0); break;
     }
   });
   ```
3. **Build**: `npm install && npx tsc` → `dist/index.js`.

**Akzeptanz-Gate P6**:
- `node dist/index.js` startet, stderr `[ccsc-bridge] token-loaded`, `pid-resolved`, `session-resolved`, `sse-connected`, `hello-received` mit connection_id.
- TypeScript-Build ohne Fehler.
- Manueller Test gegen Worker (ohne echte Claude-Session): `node dist/index.js` mit gemockter ppid+pid_start_time → SSE-Connect erfolgreich, event:inject empfangen, ACK gesendet.

---

## P7 — install-service.ps1 (LocalService + ACL)

**Ziel**: Idempotenter Service-Install als LocalService.

**Tasks**
1. `scripts/install-service.ps1` (laeuft elevated PowerShell — UAC-Prompt):
   ```powershell
   [CmdletBinding()]
   param(
     [string]$ServiceName = 'DT - cc-sessions-coord',
     [string]$PublishDir  = "$PSScriptRoot\..\dist\publish",
     [string]$DataDir     = 'C:\ProgramData\CcSessionsCoord'
   )
   if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
   # Publish
   dotnet publish "$PSScriptRoot\..\src\CcSessionsCoord.Worker" -c Release -o $PublishDir
   # Stop+Remove falls existiert
   $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
   if ($svc) {
     nssm stop $ServiceName confirm | Out-Null
     nssm remove $ServiceName confirm | Out-Null
   }
   # Install neu
   nssm install $ServiceName "$PublishDir\CcSessionsCoord.Worker.exe"
   nssm set $ServiceName ObjectName "NT AUTHORITY\LocalService"
   nssm set $ServiceName AppDirectory $PublishDir
   nssm set $ServiceName AppStdout "$DataDir\worker.stdout.log"
   nssm set $ServiceName AppStderr "$DataDir\worker.stderr.log"
   nssm set $ServiceName AppRotateFiles 1
   nssm set $ServiceName AppRotateBytes 10485760
   nssm set $ServiceName AppRestartDelay 5000
   nssm set $ServiceName Start SERVICE_AUTO_START
   # ACL Service: Authenticated Users duerfen Start/Stop/Status
   sc.exe sdset $ServiceName "D:(A;;CCLCSWRPWPDTLOCRRC;;;AU)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)" | Out-Null
   # ACL DataDir
   icacls $DataDir /inheritance:d /grant:r `
     "NT AUTHORITY\SYSTEM:(OI)(CI)(F)" `
     "NT AUTHORITY\LocalService:(OI)(CI)(M)" `
     "$($env:COMPUTERNAME)\<YOUR_WINDOWS_USER>:(OI)(CI)(M)" | Out-Null
   # Start
   nssm start $ServiceName
   # Healthcheck
   $deadline = (Get-Date).AddSeconds(30)
   while ((Get-Date) -lt $deadline) {
     try {
       $st = Invoke-RestMethod "http://127.0.0.1:7733/coord/admin/status" -TimeoutSec 2 -ErrorAction SilentlyContinue
       if ($st.uptime_sec -ge 0) { Write-Host "Service online, PID=$($st.pid)"; exit 0 }
     } catch { Start-Sleep -Milliseconds 800 }
   }
   Write-Error "Service kam nicht online"
   exit 1
   ```
2. **Idempotenz**: bei Re-run: Stop+Remove+Install — kein Halbzustand.

**Akzeptanz-Gate P7**:
- `pwsh scripts/install-service.ps1` (UAC-Prompt) → Service running, healthcheck 200.
- `Get-Service "DT - cc-sessions-coord"` → Status Running, StartType Automatic, Account LocalService.
- `Invoke-RestMethod /coord/admin/status` → 200, uptime_sec ≥ 0.
- Re-Run von `install-service.ps1` → kein Fehler, gleicher End-Zustand.

---

## P8 — Smoke-Tests `scripts/smoke-channel-push.ps1`

**Ziel**: A1-A14 als pwsh, alle gruen, exit 0.

**Tasks**
1. Helpers:
   - `Start-FakeSession <id> <pid>` — registriert Session in DB via Heartbeat-POST mit gegebenem session_id und pid (lokaler Node-Prozess als "fake claude").
   - `Send-Injection <from> <to> <text>` — POST `/coord/injections`.
   - `Wait-Delivered <injection_id> <timeoutSec>` — pollt DB `delivered_at IS NOT NULL`.
   - `Start-Bridge <sessionId> <claudePid>` — startet `node dist/index.js` als child-process, faked ppid via ENV-Workaround oder Mock-Modus.
   - `Get-BridgeLog <pid>` — stderr-Output.
2. Tests A1-A14 (Details siehe Spec §4).
3. Aggregation: jeder Test logged "PASS/FAIL [Anum]: <Detail>". Bei FAIL: `exit 1`. Am Ende `exit 0`.

**Akzeptanz-Gate P8**:
- `pwsh scripts/smoke-channel-push.ps1` → alle 14 PASS, `exit 0`.

---

## P9 — Integration `~/.claude.json`

**Ziel**: Neue Claude-Code-Session laedt Bridge automatisch.

**Tasks**
1. `~/.claude.json` patchen via `pwsh` (manuell oder via Script):
   ```json
   "mcpServers": {
     "ccsc-channel": {
       "type": "stdio",
       "command": "node",
       "args": ["<repo-root>/src/CcSessionsCoord.ChannelBridge/dist/index.js"],
       "env": {}
     }
   }
   ```
2. `profile.ps1` cc-yolo: **nicht anfassen** (User-Vorgabe).
3. Memory `feedback_mcp_env_not_inherited.md` mit Hinweis: Channel-Bridge umgeht ENV-Bug durch lokale Token-Datei-Auth.
4. Neuen README im `ChannelBridge/`-Verzeichnis (kurz: was, wo Logs, wie debug).

**Akzeptanz-Gate P9 (End-to-End)**:
- Zwei neue Claude-Code-Sitzungen starten (cc-yolo).
- In beiden: `coord status` zeigt beide sessions.
- Sitzung A: `coord injection-send <B-id> "ping"`.
- Sitzung B: zeigt `<channel source="ccsc-channel" ...>ping</channel>`-Block innerhalb 2 sec.

---

## Risiken & Mitigations (erweitert)

| Risiko | Wahrscheinlichkeit | Mitigation |
|--------|---------------------|------------|
| `notifications/claude/channel` rendert anders als Doku | Mittel | Mock-MCP-Client in P6-Akzeptanz vor full E2E |
| `wmic` deprecated | Hoch | Get-CimInstance primaer, wmic Fallback |
| NSSM install ohne Admin | Sicher | UAC-Prompt im install-service.ps1 |
| sendNotification haengt | Niedrig | 3s Timeout, ohne ACK Watchdog Resend |
| seen.json korrupt | Niedrig | try/catch + leerer State + log |
| Multi-Bridge-Race | Niedrig | Eviction-Logik in Registry |
| DB-Migration Downtime | Sehr niedrig | ALTER ADD COLUMN ist non-blocking in Postgres |
| Token-Rotation waehrend Push | Mittel | BypassCoolDownFlag erlaubt sofortigen Reconnect |
| LocalService kann Bridge-Datei (im User-Home) nicht lesen | Niedrig | Bridge-Dist im Repo-Verzeichnis, `node` als User-Process — kein LocalService-Zugriff noetig |
| Replay-Endlosschleife | Niedrig | LIMIT 200 + ORDER BY event_seq ASC + Bridge-Dedupe |

---

## Zeitplan-Schaetzung

P1: 15 min · P2: 30 min · P3: 30 min · P4: 120 min · P5: 20 min · P6: 90 min · P7: 30 min · P8: 60 min · P9: 20 min

Summe ~7 Std.

## Definition of Done (gesamt)

- [ ] Alle P1-P9 Akzeptanz-Gates gruen.
- [ ] `scripts/smoke-channel-push.ps1` exit 0.
- [ ] E2E zwei Claude-Sitzungen: Ping ≤ 2 sec.
- [ ] Pull-Pfad regressionsfrei (separater Test in smoke-Skript).
- [ ] Spec + Plan + Code committed.
- [ ] `cc-yolo` in profile.ps1 unangetastet.

## Changelog v1 → v2

- **DB-Dialekt klargestellt** (Postgres-only).
- **Reihenfolge umgestellt**: Token-Datei (P3) VOR Channel-Endpoints (P4).
- **ACK-SQL Reconnect-Bug behoben**: push_connection_id nur fuer Watchdog, nicht fuer ACK-WHERE.
- **Watchdog als BackgroundService**.
- **SSE-Header explizit dokumentiert** (Content-Type, Cache-Control, X-Accel-Buffering, FlushAsync).
- **Token-Auto-Gen idempotent**: nur bei fehlender Datei, Restart invalidiert nicht.
- **wmic primaerersatz Get-CimInstance**.
- **Akzeptanz-Gates pro Phase**: ausformuliert, jede Phase hat klare Pass/Fail-Kriterien.
- **Rollback-SQL** + Backup-Schritt vor Migration.
- **NSSM idempotent**: Re-Run sauber.
- **Service-Recovery konfiguriert** (AppRestartDelay 5000, AppRotateFiles).
