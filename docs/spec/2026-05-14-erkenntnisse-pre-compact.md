# cc-sessions-coord — Erkenntnisse und Architektur-Entscheidungen

**Extraction-Datum:** 2026-05-14  
**Quelle:** JSONL-Transcript 7-Tage-Session (2026-05-07 bis 2026-05-14), 17.285 Zeilen, 1868 User-Turns  
**Status:** Pre-Compact Snapshot vor Auto-Compact bei 83,5 %

---

## Architektur-Entscheidungen

### 1. DB-Centric statt SSE (Server-Sent Events)

**Entscheidung:** PostgreSQL LISTEN/NOTIFY als zentrales Koordinations-Primitive für Multi-Session-Orchestrierung.

**Begründung:**
- SSE erfordert immer einen aktiven HTTP-Kanal zum Client — bei Browser-Fenster-Minimierung oder temporärem Netzwerk-Ausfall würde Notification verlorengehen
- LISTEN/NOTIFY dekoppelt die Notification vom Transport-Kanal: Session speichert Nachricht in DB → Worker liest asynchron → beliebig verzögert möglich
- Greenfield-Design: Keine Legacy-Constraints, daher Datenbank als Single Source of Truth optimal
- Sequenziale Guarantees: DB-Transaktionen garantieren Ordering und Atomarität über Session-Grenzen hinweg
- Skalierung: Jede Session mit eigenem Worker-Subprocess → jeder kann unabhängig LISTEN auf seinen Channel

**Alternative geprüft:** SSE-Fallback für Session-Liveness-Detection (Pingpong) aber durch DB-Polling ersetzt — siehe unten.

### 2. Pingpong als Kern-Requirement

**Definition:** Bidirektionales Heartbeat zwischen Bridge (Hauptprozess) und Worker (Subprocess).

**Flow:**
1. Bridge sendet `{"type": "ping", "id": "uuid"}` an Worker über Worker-stdin
2. Worker parst Message → antwortet sofort `{"type": "pong", "id": "uuid"}` auf stdout
3. Bridge timeout nach N ms → Worker gilt als dead → Session-Recovery triggern

**Warum DB nicht ausreicht:**
- DB-Polling allein erkennt Worker-Crash zu spät (Poll-Intervall z.B. 5sec → bis zu 5sec Latenz)
- Pingpong ist **synchron** innerhalb Process-Lifetime, DB-Polling ist **asynchron**
- Kombination: Pingpong für Echtzeit-Liveness, DB für persistierte NachrichtenQueue über Session-Crashes hinweg

**Implementierung:**
- Bridge: Worker spawnt, `setInterval(ping)` alle 2sec
- Worker: `process.stdin.on('data', msg => { if (msg.type === 'ping') reply pong })`
- DB: `INSERT INTO pings (session_id, direction, ts)` für Audit-Trail und Recovery-Trigger

### 3. Architektur: Bridge ↔ Worker ↔ MCP-Servers

```
┌─────────────────────────────────────────────────────────────┐
│ Bridge (Main Process)                                        │
│  - Session-Lifecycle-Management                              │
│  - Worker-Spawning & Supervision                             │
│  - Pingpong-Timeout-Detection                                │
│  - DB-Listener (LISTEN session_channel_<id>)                │
│  - HTTP-Server (WS fallback später)                          │
└──────────────────┬──────────────────────────────────────────┘
                   │ stdio (MCP-Frame-Format)
                   │
┌──────────────────▼──────────────────────────────────────────┐
│ Worker (Subprocess, per Session)                            │
│  - Claude Agent SDK Integration                              │
│  - MCP-Requests dispatcher                                   │
│  - Message-to-DB-Persist (per Tool-Call Result)             │
│  - NOTIFY session_channel_<id> on State-Change              │
└──────────────────┬──────────────────────────────────────────┘
                   │ (MCP-Protocol über stdio)
                   │
         ┌─────────┴──────────────┬────────────┬────────────┐
         │                        │            │            │
    ┌────▼─────┐  ┌────────────┐ │  ┌────────▼───┐  ... weitere
    │ PostgreSQL│  │ File-Store │ │  │ Azure-Blobs│     MCP-Servers
    │ (LISTEN)  │  │            │ │  │            │
    └──────────┘  └────────────┘ │  └────────────┘
                                 │
                    ┌────────────▼──────────────┐
                    │ Claude Agent SDK         │
                    │ (Haiku/Opus4/Sonnet)     │
                    └──────────────────────────┘
```

**Nachricht-Flow für Tool-Call:**

1. **User-Prompt → Bridge:** HTTP POST `/sessions/<id>/message`
2. **Bridge → Worker:** `{"type": "message", "content": "...", "frame_id": "uuid"}`
3. **Worker → Claude SDK:** `sdk.query({prompt, tools: [...], allowedTools})`
4. **Claude → MCP-Requests:** `{"type": "use_tool", "name": "...", "input": {...}}`
5. **Worker → MCP-Server:** Tool-Request über MCP-stdio
6. **MCP-Server → Worker:** Tool-Result
7. **Worker → Claude:** Tool-Result zurück in Conversation
8. **Worker → DB:** `INSERT INTO messages (session_id, role, content, ...)`
9. **Worker → Bridge (NOTIFY):** `NOTIFY session_channel_<id>, 'message_added'`
10. **Bridge → Database:** Listener aktiviert, fetcht neueste Message
11. **Bridge → Client:** WS/HTTP-Response

### 4. MCP Environment Inheritance — Bug & Workaround

**Problem (Claude Code MCP-Subsystem):**
- Claude Code ersetzt **vollständig** die Environment-Variablen für MCP-Server-Subprozesse
- `mcpServers.env` aus settings.json wird nicht mit `process.env` des Eltern-Prozesses gemergt, sondern **ersetzt** diesen
- Folge: Wenn Bridge mit `process.env.DATABASE_URL` startet und Worker spawnt MCP-Server, hat dieser NICHT `DATABASE_URL` — nur was in `mcpServers.env` steht
- Symptom: MCP-Tools schlagen fehl mit "Connection refused" oder "env var not found"

**Root Cause:**
Claude Code's MCP-Wrapper nutzt `spawn(cmd, [], { env: mcpServersEnv })` statt `spawn(cmd, [], { env: { ...process.env, ...mcpServersEnv } })`

**Workaround (Implementiert):**

```powershell
# cc-yolo.ps1 — Temp-MCP-Config generieren
$tempMcpConfig = @{
    mcpServers = @{
        postgresql = @{
            command = "C:\tools\mcp-servers\postgresql.exe"
            env = @{
                "DATABASE_URL" = $env:DATABASE_URL
                "LOG_LEVEL" = "debug"
                # ... alle erforderlich Vars
            }
        }
    }
} | ConvertTo-Json

# Temp-File schreiben
$tempPath = "$env:TEMP\mcp-config-$(Get-Date -f yyyyMMdd-HHmmss).json"
$tempMcpConfig | Out-File $tempPath -Encoding UTF8

# Claude Code mit --mcp-config starten
claude code --mcp-config $tempPath
```

**Langfrist-Lösung:**
- Claude Code Patch: Merge statt Replace in MCP-Subsystem (Dialog mit Anthropic geführt)
- Interim: Temp-Config in Bridge vor Worker-Spawn generieren, Worker-Umgebung explizit setzen

### 5. cc-yolo PowerShell Wrapper — Verhalten & Flags

**Zweck:** Vereinfachte Session-Initiierung mit intelligenten Defaults.

**Verhalten (2026-05-14 Stand):**

```powershell
cc-yolo              # Neue Session starten (kein --name, UUID wird generiert)
cc-yolo --name test  # Neue Session mit Name "test"
cc-yolo -r <id>     # Resume Existierende Session
cc-yolo -c           # Channels-Flag laden (für Multi-Session-Listen)
```

**Implementierungs-Details:**

- `--name` wird **nur** bei Neu-Sessions mitgegeben (`-name` nicht bei resume)
- `-c` Flag injiziert `channels: true` in cc-sessions-coord Config → Bridge wird LISTEN-capable
- Wrapper echoed final Command bevor claudeCode aufgerufen wird (Debug-Trail)
- Resume-Pfade: Bridge liest Session-ID aus Argument, sucht JSONL-File unter `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`

**Profil-Snippet (2026-05-12):**
```powershell
function cc-yolo {
    param(
        [string]$name,
        [string]$r = $null,
        [switch]$c = $false
    )
    
    $args = @("code")
    
    if ($r) {
        # Resume Mode
        $args += "--session", $r
        if ($c) { $args += "--mcp-config-channels" }
    } else {
        # New Session
        if ($name) { $args += "--name", $name }
        if ($c) { $args += "--mcp-config-channels" }
    }
    
    Write-Host "Executing: cc $($args -join ' ')" -ForegroundColor Cyan
    & cc @args
}
```

---

## Bridge/Worker/Hook Architektur — Task-Division

### Bridge (Hauptprozess)

**Verantwortlichkeiten:**
1. **Session-Lebenszyklus-Verwaltung**
   - Create: Worker spawnen mit UUID, Initial-Session-Record in DB
   - Read: Session-State fetchen (DB-Query)
   - Update: Session-Metadata, Last-Activity-Timestamp
   - Delete: Worker terminieren, Session-Record soft-delete

2. **Worker-Supervision**
   - Spawn mit `child_process.spawn(workerScript, [sessionId], { stdio: 'pipe' })`
   - Monitoring: Exit-Code, Crash-Recovery, Timeout-Handling
   - Graceful Shutdown: SIGTERM → warten auf Flush → SIGKILL falls Timeout

3. **Pingpong-Heartbeat**
   - Sende alle 2sec `{"type": "ping", "id": "uuid"}` auf Worker-stdin
   - Timeout nach 5sec → Worker-Restart triggern
   - Nur für **Echtzeit-Liveness**, nicht für Nachrichtenqueue

4. **PostgreSQL LISTEN-Subsystem**
   - `LISTEN session_channel_<session-id>` pro Session
   - Auf Notification → DB-Query für neue Messages
   - Broadcast zu All Clients über HTTP/WS

5. **HTTP-Endpoint**
   - `POST /sessions/<id>/message` — Message-Injection durch Client
   - `GET /sessions/<id>` — Session-State-Abfrage
   - `WS /sessions/<id>/stream` — Real-Time-Updates (später, aktuell HTTP-Polling)

### Worker (Subprocess)

**Verantwortlichkeiten:**
1. **Claude Agent SDK Integration**
   - `sdk.query({ messages, tools, systemPrompt, model })`
   - Tool-Call-Dispatch zu MCP-Servers (mittels MCP-Wrapper)
   - Conversation-History-Management

2. **MCP-Request-Handling**
   - Beim Tool-Call: Message an MCP-Server über stdio
   - Result → zurück an Claude SDK
   - Fehlerfall: Graceful Degradation oder Retry

3. **Message-Persistence**
   - Nach **jedem** Claude-Output: `INSERT INTO messages (session_id, role='assistant', content, ...)`
   - Nach jeder Tool-Result: `INSERT INTO tool_results (session_id, tool, input, output, ...)`
   - Transaktionale Consistency

4. **State-Notifications**
   - Bei Message-Insert: `NOTIFY session_channel_<session-id>, 'message_added'`
   - Bei Tool-Call: `NOTIFY session_channel_<session-id>, 'tool_called'`
   - Bridge picked up NOTIFY → fetcht Daten, broadcasts zu Clients

5. **Pingpong-Response**
   - `process.stdin.on('data', frame => { if (frame.type === 'ping') reply pong })`
   - Muss **nicht** durch Claude-Verarbeitung gehen, sondern direkt antwortet

### Hooks (PowerShell — `.claude/hooks/`)

**Event-Trigger-Punkte:**

1. **SessionStart** (Bridge-Init)
   - Ars Contexta Vault-Status injizieren (Reminders, Insights)
   - Token-Optimizer Checkpoint laden falls vorhanden
   - MCP-Subsystem-Health-Check

2. **UserPromptSubmit** (vor Claude-Query)
   - Session-JSONL-Messung → Warn-Block bei >60% Context
   - Reminder-Injekt: Pending Tasks aus `~/.claude/memory-sync-queue/`
   - Proactive-Context-Load falls Memory-MCP verfügbar

3. **PostToolUse** (nach Tool-Call)
   - Clutter-Check: `.bak`, `.tmp`, `.new`, `.backup-*` Dateien warnen
   - Memory-Footer: "@remember() TODO: Persist diese Decision"

4. **ToolResult** (vor Claude-Resume nach Tool-Result)
   - Bei MCP-Fehler: Retry-Logic oder Fallback triggern
   - Bei PostgreSQL-Tool: Transaktions-Commit bestätigen

---

## Bekannte Bugs & Limitations

### 1. **MCP Environment Inheritance (BLOCKING)**
- **Status:** Workaround implementiert (Temp-Config), Upstream-Fix ausstehend
- **Impact:** MCP-Tools könnten Environment-Vars nicht zugreifen (z.B. DATABASE_URL)
- **Mitigation:** cc-yolo injiziert alle erforderlichen Vars vor Worker-Spawn

### 2. **Worker-PID nicht in DB (USER PREFERENCE)**
- **Status:** Entfernt (2026-05-14), nur Session-ID wird persistiert
- **Begründung:** Worker-PID ändert sich bei Restart → verwirrend für Debugging
- **Folge:** Kein direkter `ps` auf Worker möglich, nur über Session-ID → Bridge-Query

### 3. **Pingpong vs DB-Polling — Synchronization Gap**
- **Status:** Bekannt, Design deliberat
- **Issue:** Pingpong erkennt Crash (msec-Bereich), DB-Polling braucht Poll-Intervall
- **Mitigation:** Kombination: Pingpong für Echtzeit, DB für persistierte Queue

### 4. **Session-Resume mit MCP-State-Loss**
- **Status:** Teilweise gelöst
- **Issue:** Wenn Worker crasht, sind **in-flight Tool-Calls** verloren (nicht persistiert)
- **Mitigation:** Tool-Result sofort nach Completion persistieren (transaktional)
- **Future:** MCP-Checkpoint-Table für Replay bei Worker-Restart

### 5. **Channels-Flag & Selective LISTEN**
- **Status:** Design, noch nicht implementiert
- **Issue:** Bridge bisher LISTEN auf **alle** Sessions → N² Connections bei N Sessions
- **Solution:** `-c` Flag in cc-yolo → nur LISTEN auf konfigurierte Channels
- **Impact:** Skalierung für 100+ parallele Sessions

---

## Test-Strategien für Multi-Session & Pingpong

### Unit-Tests

**Pingpong-Handshake:**
```typescript
test('Worker responds to ping within 100ms', async () => {
  const worker = spawn(workerScript, [sessionId]);
  worker.stdin.write(JSON.stringify({ type: 'ping', id: 'test-1' }));
  
  const result = await waitForMessage(worker.stdout, 100);
  expect(result).toEqual({ type: 'pong', id: 'test-1' });
});
```

**Worker-Timeout-Detection:**
```typescript
test('Bridge detects worker crash after 5sec timeout', async () => {
  // Worker spawnt, wird aber nach 2sec getötet
  // Ping timeout → Session sollte Recovery triggern
  await delay(5100);
  expect(sessionState.status).toBe('recovering');
});
```

### Integration-Tests

**Multi-Session-Koordination:**
```typescript
test('Two sessions can run concurrently without interference', async () => {
  const session1 = await createSession('test-1');
  const session2 = await createSession('test-2');
  
  // Sende Message zu Session 1
  await session1.message('What is 2+2?');
  
  // Sende Message zu Session 2 (während Session 1 noch antwortet)
  await session2.message('What is 3+3?');
  
  // Beide sollten unabhängig antworten
  const res1 = await waitForMessage(session1);
  const res2 = await waitForMessage(session2);
  
  expect(res1).toContain('4');
  expect(res2).toContain('6');
});
```

**DB-Persistence nach Worker-Restart:**
```typescript
test('Messages persist across worker restart', async () => {
  const session = await createSession('test');
  
  // Sende Message 1
  await session.message('First question');
  let messages = await db.query('SELECT * FROM messages WHERE session_id = ?', [session.id]);
  expect(messages.length).toBe(1);
  
  // Worker killen
  process.kill(session.workerId);
  await delay(1000); // Bridge sollte Recovery triggern
  
  // Message 2 senden (neuer Worker)
  await session.message('Second question');
  messages = await db.query('SELECT * FROM messages WHERE session_id = ?', [session.id]);
  expect(messages.length).toBe(3); // User + Assistant + User
});
```

### Smoke-Tests (Manual)

1. **Einfache Session:**
   ```bash
   cc-yolo --name smoke-test-1
   # Prompt eingeben → Claude antwortet → Sessions beenden
   ```

2. **Zwei Sessions parallel:**
   ```bash
   cc-yolo --name smoke-test-2a &
   cc-yolo --name smoke-test-2b &
   # Beide starten, parallele Prompts senden, checken dass kein Cross-Talk
   ```

3. **Worker-Restart-Szenaario:**
   ```bash
   # Session starten, erste Nachricht senden
   cc-yolo --name smoke-test-3
   # Message eingeben, auf Response warten
   # Während Session lebt: taskkill /PID <worker-pid> /F
   # Weitere Message eingeben → sollte automatisch Recovery + Response
   ```

---

## User-Preferences & Memory-Kandidaten

### Preferences (für Hindsight-Storage)

1. **Nie "Pause/Feierabend/morgen"-Angebote machen**
   - User entscheidet alleine wann Schluss ist
   - Pausen-Vorschläge machen ihn aggressiv (Feedback 2026-05-13)

2. **Architektur-Entscheidungen sofort festhalten**
   - `remember()` nicht bis Session-Ende warten
   - Decision-Typ: "Architecture" oder "Implementation"

3. **Bugs sofort als Feedback-File**
   - Statt Text-Mention → Datei unter `~/.claude/projects/<proj>/memory/feedback_*.md`
   - Root Cause + Workaround

4. **Claude PID nicht persistieren**
   - Nur Session-ID (User-Entscheidung 2026-05-14)
   - Worker-PID ändert sich bei Restart

### Memory-Einträge für Persistent Storage

**Decision: DB-Centric über SSE**
- Type: Architecture
- Key: `cc-coord-architecture-db-vs-sse`
- Tags: `db-centric`, `postgres`, `listen-notify`

**Decision: Pingpong als Kern-Requirement**
- Type: Architecture
- Key: `cc-coord-pingpong-design`
- Tags: `worker-liveness`, `heartbeat`, `recovery`

**Feedback: MCP Environment Inheritance Bug**
- Type: Learning
- Key: `mcp-env-inheritance-bug`
- Tags: `mcp`, `bug`, `workaround`
- File: `feedback_mcp_env_not_inherited.md` (bereits persistiert)

**Decision: cc-yolo Flag-Behavior**
- Type: Implementation
- Key: `cc-yolo-wrapper-flags`
- Tags: `tooling`, `session-mgmt`

---

## Architektur-Roadmap (nächste Phase)

1. **WebSocket-Stream statt HTTP-Polling**
   - Real-time-Updates, weniger Latenz

2. **MCP-Checkpoint-Table**
   - Replay in-flight Tool-Calls bei Worker-Restart

3. **Channels-Selective-LISTEN**
   - `-c` Flag in cc-yolo implementieren
   - Skalierung für 100+ Sessions

4. **Session-Timeline-Visualization**
   - Debugging-Dashboard mit Pingpong-Heartbeat-Graph
   - Worker-Restart-Events, Message-Flow

5. **Multi-Region-Koordination** (Future)
   - Mehrere Bridge-Instanzen über DB synchronisieren
   - Session-Failover zu anderem Bridge

---

**End of Report**

Generated 2026-05-14, Pre-Compact Snapshot
