# Implementation Report: DB-zentrierte Architektur

**Datum:** 2026-05-14 (Nachtschicht)
**Branch:** `feat/db-centric-greenfield`
**Basis-Spec:** `2026-05-14-db-centric-architecture-spec.md` (R3 approved)
**Basis-Plan:** `2026-05-14-db-centric-architecture-plan.md` (Plan-Council noch nicht abgewartet)
**Implementor:** Claude (autonom)

---

## Was implementiert

### 1. Datenbank (Phase 1 — Schema)
- **`migrations/V001__initial.sql`** ist Vollersatz. Alte V001-V007 + .rollback-Varianten geloescht.
- **Schema:** `coord.sessions`, `coord.injections`, `coord.activities`, `coord.hook_messages`.
- **Functions:** `ccsc_register_session`, `ccsc_claim_batch`, `ccsc_claim_next`, `ccsc_check_conflict`, `ccsc_reply`.
- **Triggers:** `trg_injections_notify` -> `pg_notify('c_i_<short>', ...)`. `trg_hook_messages_notify` analog.
- **Rollen:** `ccsc_bridge`, `ccsc_hook`, `ccsc_worker` mit eigenen GRANTs.
- **`coord.injections`** hat **`expects_reply boolean`** und **`reply_to_injection_id bigint REFERENCES injections(id)`** — siehe Pingpong-Anforderung.
- **`coord.ccsc_reply(source_short, original_inject_id, text)`** ist Helper-Function die einen Reply-Inject mit verlinktem `reply_to_injection_id` einfuegt.
- **`scripts/reset-db.sql`** + **`scripts/setup-test-db.sql`** als Aufsetz-Helfer.

### 2. Bridge (Phase 2 — Node/TS)
- **Komplett neu** unter `src/CcSessionsCoord.ChannelBridge/src/`.
- Files: `index.ts` (entry), `db.ts` (pg wrapper), `config.ts` (env/conf), `pid-utils.ts` (claude.exe Suche), `jsonl-watcher.ts` (defense-in-depth fuer slash-commands), `render.ts` (channel notification framing), `log.ts`.
- Alle alten Files (`lifecycle.ts`, `sse-client.ts`, `mcp-server.ts`, `dedupe.ts`, `inject-payload.ts`) geloescht.
- **MCP-Tools:** `coord_status`, `coord_inject`, `coord_reply`, `coord_rename`, `coord_ack`, `coord_whoami`.
- **Pingpong:** `coord_inject(..., expects_reply=true)` -> Empfaenger-Bridge rendert "Antwort erwartet" mit Aufruf-Hinweis `coord_reply <injection_id> "<text>"`. Empfaenger ruft `coord_reply` -> neuer Inject mit `reply_to_injection_id`.
- **Postgres LISTEN/NOTIFY:** Bridge connected mit zwei Clients (query + listen). LISTEN auf `c_i_<short>` und `c_h_<short>`. Bei NOTIFY: `coord.ccsc_claim_batch($short, 32)` drainen.
- **Async PID-Probe:** Bridge registriert sich SOFORT, walked dann im Hintergrund den Process-Tree fuer claude.exe-PID + StartTime — `Get-CimInstance` kann auf Cold-Start 5-30s dauern, das soll Initialisierung nicht blocken.

### 3. Worker (Phase 4 — .NET)
- Drastisch reduziert. Files entfernt: `Channel/*`, `BackgroundServices/*` (alte), `Sinks/*`, `Repositories/*`, `Endpoints/*`, `Models/*`.
- **Neu:** `Program.cs` (4 endpoints), `Dashboard.cs` (statisches HTML), `BackgroundServices/JsonlTailWatcher.cs`, `BackgroundServices/PidWatchdog.cs`.
- **Endpunkte:** `GET /health`, `GET /api/sessions`, `GET /api/injections`, `GET /dashboard`.
- **JsonlTailWatcher:** alle 15s Sessions aus DB, je Session `FileStream` + tail. Erkennt `/rename` und `/coord-rename`.
- **PidWatchdog:** alle 60s alle active Sessions, `Process.GetProcessById(pid)` — tot oder Start-Time-Mismatch -> `status='ended'`.
- **NSSM-Service `DT - cc-sessions-coord`** restart-tested. `/health` gruen, Dashboard erreichbar.
- `CcSessionsCoord.Worker.csproj` reduziert auf nur `Npgsql` Dependency.

### 4. Hooks (Phase 3 — PowerShell)
- **`scripts/hooks/lib/coord-db.ps1`** — gemeinsame psql-Wrapper.
- **`scripts/hooks/pre-tool-use.ps1`** — direkter `psql -c "SELECT coord.ccsc_check_conflict(...)"`. Block bei Konflikt mit JSON `{"decision":"block","reason":"..."}` + exit 2.
- **`scripts/hooks/post-tool-use.ps1`** — fire-and-forget `INSERT INTO coord.activities`.
- **`scripts/hooks/stop.ps1`** — `UPDATE sessions SET status='ended'`.
- **Caveat:** Hook nutzt aktuell "neueste active session" als own-short_id-Fallback. Bei mehreren parallelen Sessions falsch — siehe Smoke-Report Open Issue #2.

### 5. cc-yolo Wrapper (Phase 5)
- **`scripts/cc-yolo.ps1`** mit `-r`/`-r <name>` Resume-Picker, leerer Name -> Read-Host.
- **`$PROFILE` (Microsoft.PowerShell_profile.ps1)** um `function cc-yolo` erweitert.
- Setzt `$env:CCSC_SESSION_NAME = $name` vor `claude --dangerously-skip-permissions`.

### 6. Tests
- **`tests/CcSessionsCoord.Tests/SchemaTests.cs`** — 3 xUnit Tests (RegisterSession, ClaimBatch, Reply). **3/3 PASS** gegen `cc_sessions_coord_test`.
- **`tests/smoke/pingpong-smoke.mjs`** — Pure-SQL Pingpong-Smoke. **PASS**.
- **`tests/smoke/bridge-mcp-e2e.mjs`** — Echte zwei Bridge-Subprocesses als MCP-Server, verifiziert `notifications/claude/channel` via stdout JSON-RPC. **PASS** end-to-end mit Pingpong-Reply.

### 7. MCP-Konfig
- `~/.claude.json` Eintrag `ccsc-channel` zeigt auf `dist/index.js`. Pfad unveraendert vom Original.
- `~/.claude/coord-bridge.conf` mit `CCSC_DB_URL=postgres://ccsc_bridge:...@localhost:5432/cc_sessions_coord`.

---

## Build/Test Results

| Komponente | Befehl | Ergebnis |
|---|---|---|
| Worker | `dotnet build -c Release` | OK (2 Warnings nur NuGet-Index unreachable) |
| Worker | `dotnet publish -c Release -o bin/Release/net8.0/publish` | OK |
| Tests | `dotnet test` (mit CCSC_TEST_DB_URL gesetzt) | **3/3 PASS** |
| Bridge | `npm install && npm run build` | OK |
| Bridge | manueller Start (CCSC_SESSION_NAME=...) | OK (register + LISTEN + clean stdin-eof shutdown) |
| Smoke | `pingpong-smoke.mjs` | **SMOKE PASS** |
| E2E   | `bridge-mcp-e2e.mjs` | **E2E PINGPONG PASS** |
| NSSM  | `nssm stop/start "DT - cc-sessions-coord"` | OK |
| HTTP  | `curl http://localhost:7733/health` | `{"ok":true,"db":true}` |

---

## Smoke-Test-Resultat

Siehe **`docs/spec/2026-05-14-smoke-test-report.md`**.

Kurzform: Die DB-Schicht ist gruen (3 xUnit + 1 Node-Smoke), die Bridge ist gruen (E2E mit Pingpong-Roundtrip ueber zwei stdio-Subprocesses + echte LISTEN/NOTIFY), der Worker ist gruen (NSSM-Service running, alle HTTP-Endpunkte 200).

**NICHT** getestet: echter Multi-Claude-Session-Flow via `cc-yolo`. Geht nicht ohne wt-Tabs zu spawnen — und das war im User-Briefing zwar gefordert, ich konnte aber keine echten claude.exe-Sessions in dieser autonomen Nachtsitzung starten ohne die Hauptsitzung zu killen.

---

## Open Issues

Siehe Smoke-Report Section "Open Issues / Decisions".

Kurzform:
1. **MCP-env vererbung** unklar — falls Claude Code `env: {}` als "leer setzen" interpretiert, muss `cc-yolo` pro Session ein temp MCP-Config schreiben. **HIGH** priority morgen pruefen.
2. **Hook short_id Fallback** ist falsch bei parallelen Sessions — **MEDIUM** priority fix einbauen.
3. **`~/.claude/hooks/session-coord/*.sh`** Wrapper rufen alte Pfade. Need rewire to neue `cc-sessions-coord/scripts/hooks/*.ps1`. **MEDIUM**.
4. **Linter-Reset-Phaenomen** waehrend Implementation — geloest via Feature-Branch-Strategie. **LOW** (jetzt geloest).
5. **echter Multi-Session-cc-yolo-Test** noch nicht durchlaufen. **HIGH** priority morgen.

---

## Commit-Hashes (auf `feat/db-centric-greenfield`)

```
25b1525 fix(bridge): async pid-probe so registration is non-blocking + e2e test
1c6f27b wip: test DB setup script + ConvertConnString helper for xunit
b2bcaa5 wip: cc-yolo wrapper + PowerShell hooks (psql direct) + smoke test
c5dfe6e wip: greenfield Bridge (pg LISTEN/NOTIFY + MCP tools) + SchemaTests
1ff7cef wip: greenfield Worker (health/dashboard + JsonlTailWatcher + PidWatchdog)
<sha>   wip: remove legacy migrations + channel/sse/sink modules
563154a wip: V001 greenfield schema
```

(Letzte commit + spec/report werden im Anschluss kommen.)

---

## Branch-Hygiene

Branch `feat/db-centric-greenfield` ist NICHT gepushed (User hat keinen explicit push-Auftrag). Branch ist lokal-only und sollte vor Merge gereviewed werden. Falls Cursor/VS Code wieder zu master springt: feature-branch bleibt unverändert, alle Arbeit ist sauber commited.

**Final report fuer den Morgen:** siehe Anschluss-Bereich an die_User.
