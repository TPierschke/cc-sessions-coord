# cc-sessions-coord — DB-zentrierte Architektur (Umsetzungsplan)

**Datum:** 2026-05-14
**Status:** Plan-Entwurf, Council R3 nach Reviewer-Feedback
**Basis-Spec:** `docs/spec/2026-05-14-db-centric-architecture-spec.md` (R3 approved)
**Council-Spec-Bericht:** `docs/spec/2026-05-14-db-centric-architecture-spec-council.md`

---

## 0. Rahmen + Lieferungs-Garantien

- **Gruene Wiese**: Userlicher Vorgabe-Cut. Keine Daten der alten Welt werden migriert (siehe Spec-Abschnitt 8 / Plan-Abschnitt 4 fuer Wegwerf-Liste). Single-User-Workstation, kein Production-Traffic — Blue/Green/Canary nicht relevant.
- **Zustellungs-Garantie**: At-least-once. `ccsc_claim_batch` mit `FOR UPDATE SKIP LOCKED` ist atomar. Bei Push-Fehler in Bridge wird `delivered_at=NULL, retry_count++` zurueckgeschrieben, max 3 Retries. claude.exe sollte Duplikate idempotent verarbeiten (kommt in der Praxis nur bei Reconnect-Races vor, < 0.1 % erwartet).
- **Duplikat-Verhalten (Worst-Case)**: Wenn eine Inject zweimal an dieselbe claude.exe geht, sieht der User die Notification doppelt. `meta.injection_id` (UUID aus `coord.injections.id::text`) ist stabil pro Inject — claude.exe-MCP-Side haelt einen LRU-Cache der letzten 256 gesehenen injection_ids und filtert Duplikate. Wenn der Cache leer war (z.B. nach Bridge-Restart): doppelte Anzeige ist akzeptabel weil sehr selten und nicht datenverlust-relevant.
- **Konsistenz**: Eventually-consistent ueber Worker-Reconciler (siehe Spec 6.1). Akzeptiert weil alle Operationen idempotent sind.
- **Audit-Erhalt**: Alte Migrationen V001-V007 werden in `migrations/archive/` verschoben (nicht geloescht), neue V001__green_field.sql liegt parallel.

## 1. Phasen-Reihenfolge

Klassischer Bottom-Up: Datenmodell zuerst, dann Push-Pfad, dann Hooks, dann Worker, dann User-Wrapper, dann End-to-End-Tests, dann Cutover. Jede Phase liefert ein lauffaehiges Zwischen-Artefakt.

| # | Phase | Output | Geschaetzte Dauer |
|---|---|---|---|
| 1 | Schema & SQL-Functions | `migrations/V001__green_field.sql` (komplettes Neu-Schema) | 1 d |
| 2 | Bridge (Node/TS) | `src/CcSessionsCoord.ChannelBridge` Rewrite | 3 d |
| 3 | Hooks (PowerShell) | `scripts/hooks/*` (PreToolUse/PostToolUse/Stop) | 1 d |
| 4 | Worker (.NET) | `src/CcSessionsCoord.Worker` Reduktion + JSONL-Watcher | 2 d |
| 5 | cc-yolo Wrapper | `scripts/cc-yolo.ps1` + PATH-Setup | 0.5 d |
| 6 | Smoke- + End-to-End-Tests | `tests/e2e/*` | 1.5 d |
| 7 | Cutover + Doku | NSSM-Reinstall, README, AGENTS.md, CLAUDE.md | 0.5 d |

**Summe:** ~9.5 Tage, alleinverantwortlich. Bei Council-Iterationen am Plan und nicht-trivialen Spec-Anpassungen entsprechend mehr.

---

## 2. Pro Phase

### Phase 1 — Schema & SQL-Functions

**Files:**
- `migrations/V001__green_field.sql` (Vollersatz, kein Inkrement gegen die alte Welt)
- `scripts/audit-grants.sql` (GRANT-Soll-Vergleich)
- `tests/sql/01_schema.sql`, `02_claim.sql`, `03_check_conflict.sql`, `04_register.sql`

**Sub-Tasks:**
1. `CREATE SCHEMA coord;` plus alle DOMAINs (`coord.short_id`).
2. Vier Tabellen + Indizes + CHECK + FKs **wie in Spec 4 spezifiziert**.
3. Trigger-Funktionen `trg_inj_notify` und `trg_hook_notify` + Trigger-Bindings.
4. SQL-Functions `ccsc_claim_batch`, `ccsc_check_conflict`, `ccsc_register_session`, `ccsc_emit_injection` (siehe Spec 7.1).
5. Drei Rollen `ccsc_bridge` / `ccsc_hook` / `ccsc_worker` mit den GRANTs aus Spec 4.3.
6. `pgcrypto` Extension (fuer `gen_random_bytes`) im V001 sicherstellen.
7. SQL-Test-Suite mit `pgTAP` oder einfach `psql`-Skripten: Trigger feuert NOTIFY auf richtigem Channel; Claim atomic unter parallelen Lasttests (z.B. 100 paralleler Bridges per Bash-Loop); Foreign-Key-Cascade-Verhalten; Domain-Check schlaegt fehl bei nicht-hex short_id.

**Akzeptanz-Kriterien:**
- `psql -d ccsc -f migrations/V001__green_field.sql` laeuft idempotent durch (zweimal nacheinander — keine Fehler, kein Daten-Verlust).
- Alle SQL-Tests gruen.
- `audit-grants.sql` produziert leere Diff-Ausgabe.

---

### Phase 2 — Bridge (Node/TS)

**Files:**
- `src/CcSessionsCoord.ChannelBridge/src/index.ts` (MCP-Server Entry)
- `src/CcSessionsCoord.ChannelBridge/src/db.ts` (Postgres-Client mit `pg`-Lib, LISTEN-Reconnect-Loop)
- `src/CcSessionsCoord.ChannelBridge/src/handshake.ts` (capability detection)
- `src/CcSessionsCoord.ChannelBridge/src/claim-loop.ts` (NOTIFY-Wakeup → drain via ccsc_claim_batch)
- `src/CcSessionsCoord.ChannelBridge/src/jsonl-watcher.ts` (FileWatch eigene JSONL, idempotent UPDATE display_name)
- `src/CcSessionsCoord.ChannelBridge/src/tools/*.ts` (MCP-Tools: coord_status, coord_inject, coord_rename, coord_resolve_conflict, coord_pull_pending)
- `src/CcSessionsCoord.ChannelBridge/package.json` + `tsconfig.json`

**Sub-Tasks:**
1. Alten Channel-Push-Code, Worker-HTTP-Calls, Bearer-Token-Logik entfernen.
2. `pg`-Pool-Connection als `ccsc_bridge`, single LISTEN-Connection (kein Pool wegen LISTEN-State-Bindung).
3. Beim MCP-Init `ccsc_register_session` aufrufen, `short_id` merken, dann `LISTEN c_i_<short_id>; LISTEN c_h_<short_id>`.
4. Reconnect-Loop mit Exponential-Backoff + Jitter (`1s, 2s, 4s, ... max 30s`). Bei Reconnect re-LISTEN + einmaliger Drain ueber `ccsc_claim_batch(short_id, 100)`.
5. `claim-loop.ts` reagiert auf `pg.on('notification')` und drained pro Wakeup alle Rows (Schleife bis Result-Set leer).
6. Push an claude.exe ueber `notifications/claude/channel` mit `meta.kind`, `meta.injection_id`, `meta.source_session`. Bei Push-Fehler Compensating-UPDATE auf `delivered_at=NULL, retry_count+1` (bis 3x).
7. MCP-Tools implementieren: `coord_inject` macht `SELECT coord.ccsc_emit_injection(...)`; `coord_status` macht SELECT auf `coord.sessions`; `coord_pull_pending` Fallback wenn `claude/channel` fehlt.
8. JSONL-FileWatch parallel; idempotenter UPDATE auf display_name.
9. Tests: `vitest` mit Mocked-pg-Pool fuer Unit-Logic; ein Integration-Test gegen lokale Postgres-Instance per Docker.

**Akzeptanz-Kriterien:**
- `npm run build && npm test` gruen.
- Bridge starten mit `CCSC_SESSION_NAME=test`, `psql` einen Inject einfuegen — Bridge logged "delivered injection #N" innerhalb **< 100 ms** (lokale DB).
- claude.exe kann die Bridge als stdio-MCP laden; `coord_status` MCP-Tool returnt JSON mit aktiver Sitzung innerhalb **< 200 ms**.
- Bridge-Restart waehrend laufender Inject-Burst (50 Injects/s waehrend SIGKILL+Restart) verliert keine Nachrichten — Drain holt alles binnen 2 s nach.
- Memory-Footprint Bridge < 80 MB RSS bei 1000 Injects.

---

### Phase 3 — Hooks (PowerShell)

**Files:**
- `scripts/hooks/pre-tool-use.ps1`
- `scripts/hooks/post-tool-use.ps1`
- `scripts/hooks/stop.ps1`
- `scripts/hooks/lib/coord-db.ps1` (gemeinsame psql-Wrapper-Funktionen, Timeout-Handling, fail-open-Logging)
- `scripts/hooks/install.ps1` (Setzt `core.hooksPath` oder `.claude/settings.json`-Eintrag)

**Sub-Tasks:**
1. `lib/coord-db.ps1`: Funktion `Invoke-CoordCheck($sid, $tool, $path)` mit `statement_timeout` aus `CCSC_HOOK_TIMEOUT_MS` (Default 80 ms). Returnt Konflikt-Row oder `$null`.
2. `pre-tool-use.ps1`: liest stdin (Tool-Call-JSON), prueft `tool_name in ('Edit','Write','MultiEdit')`, ruft Check. Bei Konflikt-Row schreibt JSON `{decision:"block",reason:"..."}` auf stdout und `exit 2`. Bei Timeout: fail-open-Logik aus Spec 2.3 (Lokal-Log + Counter-Increment).
3. `post-tool-use.ps1`: async Background-Job (`Start-Job` mit `Receive-Job -Wait`-Pattern oder einfach `& psql ... &` ohne Wait), schreibt `coord.activities`-Row.
4. `stop.ps1`: setzt Session `status='ended', ended_at=now()`.
5. Fail-Open-Log-Datei `~/.claude/ccsc-failopen.log` mit Lock-File-Schutz (PowerShell `Get-FileShare`).
6. Circuit-Breaker-State im File `~/.claude/ccsc-degraded` mit Timestamp; pre-tool-use prueft Alter und entscheidet open/closed.
7. `install.ps1`: schreibt Hook-Pfade in passenden Konfigurations-Bereich (`.claude/settings.json` `hooks`-Sektion).

**Akzeptanz-Kriterien:**
- Manueller Test: Sitzung A editiert File X → Sitzung B versucht denselben File zu editieren → PreToolUse-Hook blockt mit korrekter Sitzungs-ID im `reason`, **innerhalb 100 ms (lokal) / 250 ms (Remote)**.
- PostToolUse-Latenz < 5 ms (Hook gibt sofort zurueck, DB-Write im Hintergrund).
- DB-Stop: 10 Tool-Calls innerhalb 30 s erzeugen 10 Eintraege in `ccsc-failopen.log`, beim 11. schaltet Circuit-Breaker auf closed.
- 95-Perzentil-Latenz Conflict-Check ueber 1000 Runs < 60 ms (lokal) / 180 ms (Remote).

---

### Phase 4 — Worker (.NET)

**Files:**
- `src/CcSessionsCoord.Worker/Program.cs` (vereinfacht)
- `src/CcSessionsCoord.Worker/Endpoints/Health.cs`
- `src/CcSessionsCoord.Worker/Endpoints/Dashboard.cs`
- `src/CcSessionsCoord.Worker/Jobs/JsonlTailWatcher.cs`
- `src/CcSessionsCoord.Worker/Jobs/SessionWatchdog.cs`
- `src/CcSessionsCoord.Worker/Jobs/FailOpenDrainer.cs`
- `src/CcSessionsCoord.Worker/Jobs/RetentionCleaner.cs`
- `src/CcSessionsCoord.Worker/wwwroot/dashboard.html`

**Sub-Tasks:**
1. Bestehende SSE/Push/Channel-Registry/Token-Store-Module loeschen (siehe Cutover-Liste).
2. `/health` macht `SELECT 1` + prueft `pg_notification_queue_usage()`; rot wenn > 0.5 oder DB nicht antwortet in 1 s.
3. `/dashboard` serviert statisches HTML; JS macht periodische Fetches gegen kleine Read-API `/api/sessions`, `/api/activity`.
4. `JsonlTailWatcher`: alle 5 s `SELECT short_id, claude_session_id, jsonl_path FROM coord.sessions WHERE status='active'`. Pro Eintrag `FileSystemWatcher` + Tail. Parser fuer `/coord-*`-Slash-Commands (Dispatcher-Map). Initial implementiert: `/coord-rename`.
5. `SessionWatchdog`: alle 30 s alle aktiven Sessions; `Process.GetProcessById(pid)` nicht existent → `UPDATE status='ended', ended_at=now()`.
6. `FailOpenDrainer`: alle 60 s alle aktiven `cwd`-Pfade durchlaufen, falls `~/.claude/ccsc-failopen.log` existiert: parse + Batch-Insert in `coord.activities`, lokale Datei rotieren.
7. `RetentionCleaner`: taeglich `DELETE FROM coord.activities WHERE created_at < now() - interval '90 days'`.

**Akzeptanz-Kriterien:**
- `dotnet test` gruen.
- `dotnet run` startet, `/health` returnt 200, `/dashboard` rendert Sitzungs-Liste.
- `/coord-rename "Neuer Name"` in claude.exe → innerhalb 6 s ist `display_name` in DB aktualisiert.
- Tote PIDs werden nach 30 s als `ended` markiert.

---

### Phase 5 — cc-yolo Wrapper

**Files:**
- `scripts/cc-yolo.ps1`
- `scripts/install-cc-yolo.ps1` (PATH-Setup, Aliase)

**Sub-Tasks:**
1. Argument-Parsing: `-r` flag, optionaler Resume-Name, positional args via `($args -join ' ').Trim()`.
2. Read-Host-Fallback bei leerem Namen.
3. Resume-Picker: `Get-ChildItem ~/.claude/projects/<encoded-cwd>/*.jsonl | Sort-Object LastWriteTime -Desc | Select -First 20` als interaktive Auswahl.
4. `claude --version` Vorpruefung; bei Fehler abbrechen.
5. `$env:CCSC_SESSION_NAME = $name`; dann `& claude @PassThruArgs` ohne `--dangerously-skip-permissions` als Default. Flag nur wenn `$env:CCSC_YOLO_PERMISSIONS = '1'` gesetzt ist (explicit opt-in pro Workstation, Default sicher). Resume-Flag wenn `-r`.
6. `install-cc-yolo.ps1` legt Alias in `$PROFILE` und schreibt sich selbst in `$env:Path`.

**Akzeptanz-Kriterien:**
- `cc-yolo MeinName` → claude startet, Bridge legt Sitzung mit `display_name='MeinName'` an.
- `cc-yolo -r MeinName` → Resume-Picker zeigt nur Sitzung "MeinName".
- `cc-yolo Mein Name mit Leerzeichen` → display_name = "Mein Name mit Leerzeichen".

---

### Phase 6 — Smoke- + End-to-End-Tests

**Files:**
- `tests/e2e/01_two-sessions-inject.ps1`
- `tests/e2e/02_conflict-block.ps1`
- `tests/e2e/03_db-restart-recovery.ps1`
- `tests/e2e/04_circuit-breaker.ps1`
- `tests/e2e/05_rename-via-jsonl.ps1`
- `tests/stress/01_inject-burst.ps1` — 1000 Injects in 10 s, alle ausgeliefert, p95 < 100 ms
- `tests/stress/02_reconnect-storm.ps1` — 20 Bridges, Postgres-Restart, alle reconnecten und drainen innerhalb 30 s ohne Verlust
- `tests/stress/03_failopen-flood.ps1` — DB blockiert, 200 PreToolUse-Aufrufe; alle in `ccsc-failopen.log`, Worker drained nach DB-Recovery innerhalb 60 s
- `tests/stress/04_restore-rehearsal.ps1` — pg_restore aus Cutover-Backup in Staging-DB, dann alle E2E gegen Restore-Stand; misst Restore-Dauer (Erwartung < 5 min bei <50 MB Dump-Groesse)
- `tests/stress/05_dedup-claude.ps1` — startet echte claude.exe-Sitzung mit Bridge-MCP, simuliert Reconnect-Race der dieselbe Inject zweimal liefert, verifiziert dass MCP-Client-LRU-Cache die Duplikat-Anzeige unterdrueckt
- `tests/stress/06_soak-24h.ps1` — 24 h Dauerbetrieb mit 5 Sitzungen, 1 Inject/Minute pro Sitzung, periodischen Postgres-Restarts (alle 4 h), Memory/Connection-Leak-Check (RSS und `pg_stat_activity`-Count duerfen nicht monoton steigen)
- `tests/stress/07_windows-edgecase.ps1` — Hook-Locking unter Antivirus-Scan-Last, NTFS-locks, Network-Home-Pfade — verifiziert dass `~/.claude/ccsc-failopen.log` nie korruptiert wird

**Sub-Tasks:**
1. Test 01: Zwei `cc-yolo`-Sitzungen starten, in A `coord_inject(target=B)` aufrufen, in B sollte innerhalb 1 s die Inject sichtbar sein.
2. Test 02: Sitzung A editiert File X, Sitzung B versucht denselben → PreToolUse blockt mit klarer Fehlermeldung.
3. Test 03: Postgres-Service kurz stoppen (15 s), in der Zeit Tool-Calls in A → lokale fail-open-Log wachst; Postgres wieder hoch → Worker drained Log binnen 60 s in `coord.activities`.
4. Test 04: DB-Verbindungs-IP per Firewall blocken, 11 Tool-Calls innerhalb 30 s ausloesen → Circuit-Breaker schaltet auf closed, Bridge zeigt Warnung.
5. Test 05: `/coord-rename "Test123"` in laufender Sitzung → DB-display_name ist binnen 6 s "Test123".

**Akzeptanz-Kriterien:**
- Alle 5 E2E + 4 Stress-Tests laufen gruen.
- Test-Runner `tests/run-e2e.ps1` startet alle nacheinander, raeumt zwischen den Tests auf.
- Restore-Rehearsal-Skript laeuft vor Cutover Pflicht (siehe Phase 7).

---

### Phase 7 — Cutover + Doku

**Files:**
- `README.md` (Update auf neue Architektur)
- `AGENTS.md` (Update Onboarding)
- `CLAUDE.md` (Update Naming + Workflow)
- `scripts/install-services.ps1` (NSSM: nur `DT - ccsc-worker`)
- `docs/spec/2026-05-14-db-centric-architecture-cutover.md` (Schritte fuer Live-Schwenk)

**Sub-Tasks:**
1. Alte NSSM-Services `DT - ccsc-bridge`, `DT - ccsc-worker` (alte Variante) deinstallieren.
2. Neuer Service `DT - ccsc-worker` (schlank, .NET-Worker). Bridge laeuft NICHT als Service — startet pro claude.exe-Sitzung via MCP-stdio.
3. Alte `migrations/V001-V007` werden NACH `migrations/archive/` verschoben (Audit-Trail bleibt). Tooling-Regel: alle Migrations-Runner-Skripte (`scripts/apply-migrations.ps1`, NSSM-Migrations-Step etc.) iterieren explizit nur ueber `migrations/V*.sql` direkt im Stamm-Ordner, NIE rekursiv. `migrations/archive/README.md` warnt: "VERSCHOBENE LEGACY-MIGRATIONEN. NICHT AUSFUEHREN. Diese werden vom Tool ignoriert." Version-Collision-Policy: die neue `V001__green_field.sql` darf **denselben** Filenamen wie die alte `V001__initial.sql` haben (alte ist in `archive/`), weil sie eine andere Hash-Pruefsumme hat. Tool prueft pre-flight die Pruefsumme aller `V*.sql` im Stamm und meldet bei Konflikt mit Flyway-Schema-History. Bestehende DB wird gedumped (`pg_dump ccsc | gzip > ~/backups/ccsc_legacy_2026-05-14.sql.gz`) und dann gedropped.
4. `DROP SCHEMA coord CASCADE; CREATE SCHEMA coord; \i migrations/V001__green_field.sql`.
5. Dokumentation aktualisieren — alte Channel-Push-/SSE-/Token-Konzepte raus.

**Akzeptanz-Kriterien:**
- `nssm status "DT - ccsc-worker"` returnt `SERVICE_RUNNING`.
- Alte Services nicht mehr in `services.msc`.
- `~/backups/ccsc_legacy_2026-05-14.sql.gz` existiert und ist > 0 Bytes.
- README/AGENTS/CLAUDE.md erwaehnen keine Begriffe wie "Channel-Registry", "SSE", "Bearer-Token", "InjectionPublisher".

---

## 2.1 Eskalationsregeln bei Metrik-Verfehlung

Pro Akzeptanz-Kriterium definierte Toleranz und Eskalation:

| Metrik | Soll | Toleranz | Bei Verfehlung |
|---|---|---|---|
| Bridge-Push-Latenz (lokal) | < 100 ms | bis 200 ms | Warnung im Test-Report, weitermachen |
| Bridge-Push-Latenz (lokal) | < 100 ms | > 200 ms | Phase BLOCKED — Issue oeffnen, Optimierung vor Cutover |
| PreToolUse p95 (lokal) | < 60 ms | bis 100 ms | Warnung |
| PreToolUse p95 (lokal) | < 60 ms | > 100 ms | Timeout-Konfig anpassen, neu testen |
| Reconnect-Drain | < 30 s | bis 60 s | Backoff-Tuning |
| Reconnect-Drain | < 30 s | > 60 s | Phase BLOCKED |
| Memory-Footprint Bridge | < 80 MB | bis 150 MB | Profilieren, Memory-Leak-Test |
| Restore-Dauer (Rehearsal) | < 5 min | bis 10 min | OK fuer Single-User, weitermachen |
| Restore-Dauer | < 5 min | > 10 min | Backup-Strategie ueberdenken (Compression, Split) |

Bei BLOCKED-Stand: nicht zur naechsten Phase, Issue + Council-Mini-Review.

## 3. Test-Strategie

| Level | Was | Tools | Wo |
|---|---|---|---|
| **Unit** | SQL-Functions isoliert | `psql -f` mit Fixture-Daten | `tests/sql/` |
| **Unit** | Bridge MCP-Handler | `vitest` mit Mocked-pg | `src/.../tests/` |
| **Unit** | Worker-Jobs | `xunit` mit In-Memory-Pg via Testcontainers | `tests/CcSessionsCoord.Worker.Tests/` |
| **Smoke** | Pro Phase ein Boot-Test | PowerShell-Skripte | `tests/smoke/` |
| **E2E** | Multi-Session-Szenarien | echte cc-yolo-Sessions, echte DB | `tests/e2e/` |

Pflicht: vor jedem Cutover-Step alle 4 Levels gruen.

---

## 4. Cutover-Plan

**Wegwerf-Liste (loeschen):**
- `migrations/V001__initial.sql` bis `V007__session_client.sql` (alle) → durch eine V001__green_field.sql ersetzt
- `migrations/V006__channel_push.rollback.sql`, `V007__session_client.rollback.sql`
- `src/CcSessionsCoord.Worker/Channel/*` (InjectionPublisher, ChannelRegistry, SSE-Hub)
- `src/CcSessionsCoord.Worker/Auth/*` (Bearer-Token-Store)
- `src/CcSessionsCoord.Worker/Endpoints/Inject*.cs` (HTTP-Push-Endpunkte)
- Alte Bridge-Module: alles ausser stdio-MCP-Skelett
- Alte Hook-Skripte ausser PreToolUse/PostToolUse/Stop (UserPromptSubmit/SessionStart/SessionEnd raus)
- `scripts/coord-subcommands.ps1` (wird durch Worker-JSONL-Watcher ersetzt)

**Schritte (Live-Schwenk):**
1. **Restore-Rehearsal vorab** in Staging-DB: `pg_dump ccsc | psql -h localhost -d ccsc_staging`, dann `tests/stress/04_restore-rehearsal.ps1`. Erst weiter wenn alles gruen.
2. DB-Dump als Archiv: `pg_dump ccsc | gzip > ~/backups/ccsc_legacy_2026-05-14.sql.gz`. Pruefsumme + Groesse in `~/backups/ccsc_legacy_2026-05-14.sha256` + `~/backups/ccsc_legacy_2026-05-14.meta`.
3. Alte NSSM-Services stoppen + deinstallieren.
4. Snapshot von `services.msc`-Stand in `~/backups/nssm-state-2026-05-14.txt` (Rollback-Referenz).
5. `DROP SCHEMA coord CASCADE;` per psql — verlangt explicit `--confirm`-Flag im Cutover-Skript (zweiter `Read-Host`-Prompt mit Eingabe "DROP").
6. `psql -d ccsc -f migrations/V001__green_field.sql`.
7. Worker neu builden, NSSM-Service `DT - ccsc-worker` installieren + starten.
8. Bestehendes `claude.exe`-MCP-Config umstellen auf neuen Bridge-Pfad (stdio).
9. `cc-yolo TestSession` starten → smoke-test. Wenn fail: Rollback-Strategie 5 (kompletter Revert).
10. Falls alles gut: alte Wegwerf-Files in Commit aufnehmen + `migrations/archive/` einchecken.

---

## 5. Rollback-Strategie

**Wenn Phase 1 (Schema) fehlschlaegt:** `DROP SCHEMA coord CASCADE` und alten Schema-Dump zurueckspielen — alte Welt war schon weg, aber neuer Worker und Bridge sind noch nicht aktiv.

**Wenn Phase 2/3 (Bridge/Hooks) fehlschlaegt:** Schema bleibt, Hooks zurueck auf alte Variante (Git-Branch `pre-greenfield`), Worker bleibt aus.

**Wenn Phase 4-5 fehlschlaegt:** Worker-NSSM-Service deinstallieren, JSONL-Tail-Watcher faellt aus → Rename via `/coord-rename` funktioniert nicht mehr, aber Bridge + Hooks laufen weiter. Nicht kritisch.

**Wenn alles fehlschlaegt (Full-Revert, Erwartung 15-20 min wall-clock)**:
1. `git checkout master@before-greenfield` (Tag wird vor Cutover-Schritt 5 gesetzt). [~30 s]
2. SHA256-Validierung der Backup-Datei (`sha256sum -c ~/backups/ccsc_legacy_2026-05-14.sha256`). Bei Mismatch: STOP, Maschine im Halb-Zustand belassen, User eskalieren. [~10 s]
3. `DROP SCHEMA coord CASCADE; gunzip -c ~/backups/ccsc_legacy_2026-05-14.sql.gz | psql -d ccsc` (Restore aus archiviertem Dump). [erwartete Dauer ~5 min bei <50 MB Dump, gemessen in Phase 6 Restore-Rehearsal]
4. NSSM-Services aus Backup-Liste neu installieren (`scripts/restore-nssm.ps1 ~/backups/nssm-state-2026-05-14.txt`). [~2 min]
5. claude.exe MCP-Config zurueck auf alten Bridge-Pfad (vor Cutover war es der alte Channel-Bridge-Pfad). [~1 min manuell]
6. Validierung: `dotnet test` gegen alte Worker + smoke-test mit `cc-yolo`-Pendant. [~5 min]

**Teilversagen-Strategie** (Full-Revert bricht selbst ab):
- Schritt 2 (SHA-Mismatch) → STOP, Eskalation, da Backup ohnehin nicht verlaesslich. Optionen: zweites Backup einer aelteren Maschine, oder Neu-Aufbau ohne Daten (akzeptabel weil gruene Wiese).
- Schritt 3 (psql-Restore-Fehler) → Restore wiederholen mit `--single-transaction`; bei wiederholtem Fehler: User-Eskalation, manuelle Reparatur.
- Schritt 4 (NSSM-Skript-Fehler) → Services manuell aus `services.msc` registrieren mit `nssm install` direkt, basierend auf der Liste.
- Schritt 6 (Smoke-Test fail) → System im halb-restored Zustand belassen, User-Eskalation. NICHT erneut DROPen.

Ablauf wurde in Restore-Rehearsal (Cutover-Schritt 1) bereits getestet — Full-Revert ist nicht spekulativ.

---

## 6. Risiko-Liste (nach Prioritaet)

Priorisierung: **P0** = sofortiges Risiko fuer Cutover-Erfolg, MUSS vor Live-Schwenk validiert sein. **P1** = wichtig, Mitigation einrichten. **P2** = Restrisiko, Monitoring genuegt.

| P | Risiko | Eintritt | Schaden | Mitigation |
|---|---|---|---|---|
| P0 | Cutover-Schritt schiesst Production-DB ab (fehlender `--confirm`) | sehr gering | sehr hoch | zweiter `Read-Host "DROP"`-Prompt + Pruefsumme der Archive-Datei vor DROP |
| P0 | Restore-Dump unbrauchbar (corrupt) | gering | hoch | SHA256-Pruefsumme + Test-Restore im Rehearsal vor Cutover |
| P0 | Schema-Migration loescht versehentlich noch unmigrierte Daten | hoch | mittel | Pflicht-Dump vor `DROP SCHEMA`; Cutover-Skript verlangt explicit `--confirm` |
| P0 | `gen_random_bytes` nicht verfuegbar (kein `pgcrypto`) | gering | hoch | V001 prueft `CREATE EXTENSION IF NOT EXISTS pgcrypto;` zuerst, Restore-Rehearsal verifiziert Extension-State |
| P1 | MCP-Capability `claude/channel` faellt aus (claude.exe-Update) | mittel | hoch | Pull-Tool-Fallback `coord_pull_pending`, CI-Test der Handshake-Response |
| P1 | Anthropic-Provider-Ausfall im opencode-MCP (Council-Limitierung) | hoch | mittel | Spec/Plan dokumentieren das transparent; Council reduziert auf 2/3 |
| P1 | Bridge stirbt → Session-Channel down | mittel | mittel | claude.exe-MCP-Auto-Reconnect; Worker-Watchdog markiert tote Sitzung |
| P1 | Hooks haengen 80 ms bei jedem Edit (User-merklich) | mittel | gering | Konfigurierbar, fail-open Default lokal, Circuit-Breaker |
| P1 | `migrations/archive/` wird von neuer Tooling-Version aus Versehen ausgefuehrt | gering | mittel | Tool iteriert nur Stamm-Ordner; `archive/README.md` mit Warnung; Pruefsumme-Validierung |
| P2 | Postgres-NOTIFY-Queue voll (`pg_notification_queue_usage()` > 0.5) | gering | mittel | Worker-/health/ checkt; Bridge-Drosselung pro Sitzung 20 Injects/10 s |
| P2 | Worker-Service stirbt → kein JSONL-Tail | mittel | gering | NSSM-Restart-on-Failure; Bridge-FileWatch als Fallback |
| P2 | At-least-once verursacht Duplikat-Inject sichtbar fuer User | gering | gering | meta.injection_id stabil; LRU-Cache 256 IDs in MCP-Client |
| P2 | `cc-yolo` aliased dasselbe wie ein bestehender Befehl | gering | gering | install-Skript prueft `Get-Command cc-yolo` und warnt |

---

**Naechster Schritt:** Council-Review des Plans (Phase D des Master-Auftrags).
