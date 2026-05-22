# Smoke-Test-Report: DB-zentrierte Architektur

**Datum:** 2026-05-14
**Branch:** `feat/db-centric-greenfield`
**Spec:** `2026-05-14-db-centric-architecture-spec.md`
**Plan:** `2026-05-14-db-centric-architecture-plan.md`

---

## Test-Matrix

| # | Test | Variante | Ergebnis |
|---|---|---|---|
| 1 | `psql -f V001__initial.sql` | Reset + Apply | OK |
| 2 | `coord.ccsc_register_session` | 2 Sessions registriert | OK (short_id-Vergabe) |
| 3 | `coord.ccsc_check_conflict` | Aus eigener Sicht / Aus anderer Sicht | OK / OK |
| 4 | `INSERT injection` triggers NOTIFY | c_i_<target> | OK |
| 5 | `coord.ccsc_claim_batch` mit SKIP LOCKED | atomar | OK |
| 6 | `coord.ccsc_reply` | reply_to_injection_id verkettet | OK |
| 7 | Smoke-Test (DB direkt, ohne MCP) | `tests/smoke/pingpong-smoke.mjs` | **PASS** |
| 8 | xUnit-Tests (3 Tests) | `tests/CcSessionsCoord.Tests/SchemaTests.cs` | **3/3 PASS** |
| 9 | Worker `dotnet build -c Release` | Release-Build | **PASS** |
| 10 | Worker `dotnet publish` + NSSM-Restart | Service-Restart | **PASS** |
| 11 | Worker `/health` HTTP | `{"ok":true,"db":true}` | **PASS** |
| 12 | Worker `/api/sessions` HTTP | Liste der Sessions | **PASS** |
| 13 | Worker `/api/injections` HTTP | Liste mit Pingpong-Reply | **PASS** |
| 14 | Worker `/dashboard` HTTP | HTML 200 | **PASS** |
| 15 | Bridge `npm run build` | TypeScript-Build | **PASS** |
| 16 | Bridge stdio Manueller Start | registers + LISTEN + clean shutdown | **PASS** |
| 17 | **E2E Pingpong** (`bridge-mcp-e2e.mjs`) | 2 Bridge-Subprocesse, A->B mit expects_reply, B replies, A claimt Reply | **PASS** |

---

## E2E-Beweis (Auszug aus Lauf)

```
[A] session-registered | 7838c55a
[B] session-registered | 42b545bd
-> A injected #3 to B
[B] notify | c_i_42b545bd | {"payload":"3"}
[B] drain | c_i_42b545bd | {"count":1}
[B] got channel notification: id=3
OK: B received notification id=3
-> B replied with #4
[A] notify | c_i_7838c55a | {"payload":"4"}
[A] drain | c_i_7838c55a | {"count":1}
[A] got channel notification: id=4 text="Pong"
OK: A received reply id=4 reply_to=3
E2E PINGPONG PASS
```

Die Notification wurde ueber stdout (JSON-RPC `notifications/claude/channel`) an den Bridge-Parent (in echt: `claude.exe`, im Test: das E2E-Skript) gesendet, NICHT ueber den Worker. Der reply_to_injection_id-Header ist im Reply-Notification-`meta`-Block korrekt sichtbar.

---

## Schema-Smoketest-Beweis

```sql
-- Inject
INSERT INTO coord.injections(source_short_id, target_short_id, inject_text, expects_reply)
VALUES ('A', 'B', 'antworte mit Pong', true);
-- pg_notify('c_i_B', '1') fires

-- B claims
SELECT * FROM coord.ccsc_claim_batch('B', 32);
-- returns row id=1, expects_reply=true, delivered_at=now()

-- B replies
SELECT coord.ccsc_reply('B', 1, 'Pong');
-- INSERT id=2, source='B', target='A', kind='reply', reply_to_injection_id=1
-- pg_notify('c_i_A', '2') fires

-- A claims
SELECT * FROM coord.ccsc_claim_batch('A', 32);
-- returns row id=2, kind='reply', reply_to_injection_id=1
```

---

## Open Issues / Decisions

1. **MCP-env via Claude Code**: Die User-Notiz im Memory sagt "Claude Code ersetzt mcpServers.env komplett". Aktueller MCP-Eintrag `ccsc-channel` in `~/.claude.json` hat `env: {}`. Der manuelle Bridge-Test und der E2E-Test zeigen: wenn `CCSC_SESSION_NAME` als Parent-Env gesetzt ist (was `cc-yolo` macht via `$env:CCSC_SESSION_NAME`), wird die Bridge erfolgreich gestartet. **Falls Claude Code env truly NICHT vererbt**, muesste `cc-yolo` einen pro-Sitzung MCP-Config-File mit explicit `env` schreiben (siehe Memory-Eintrag `feedback_mcp_env_not_inherited`). Das ist NICHT in Phase 1 implementiert — Quick-Fix wenn es klemmt: explizite env in `~/.claude.json` setzen.

2. **PreToolUse-Hook short_id-Erkennung**: Mein Hook benutzt aktuell "neueste active session" als Fallback wenn `CCSC_SHORT_ID` env nicht gesetzt ist. Bei mehreren parallelen Sessions ist das **NICHT korrekt**. Bessere Loesung: cc-yolo schreibt nach Bridge-Start die `short_id` in eine PID-spezifische Datei wie `~/.claude/coord-bridge-state/$PID.short` und der Hook liest die anhand der eigenen Process-Tree-PID. Vorlaeufiger Workaround: env `CCSC_SHORT_ID` manuell setzen oder Hook-System initial nicht verwenden. **TODO fuer den Morgen.**

3. **Worker-Service**: Laeuft als Postgres-Superuser. Sollte besser auf `ccsc_worker`-Rolle umgestellt werden — aber die Rolle braucht ggf. mehr Permissions als aktuell (z.B. SELECT auf jsonl_path). Aktuell funktioniert es, kein Bug.

4. **Linter-Reset-Phenomen**: Waehrend der Implementierung wurden mehrfach `migrations/V001__initial.sql`, `src/CcSessionsCoord.Worker/Program.cs` und Bridge-`src/*.ts` zurueck auf alten Stand reset, vermutlich durch einen automatischen Linter-Hook oder Editor-Sync. Workaround: ich bin auf eine Feature-Branch (`feat/db-centric-greenfield`) gewechselt und habe inkrementell committed — Branch hat das Problem geloest. Empfehlung: Branch beibehalten und nach Review zu master mergen.

5. **`/coord-rename` aus claude.exe**: JSONL-Tail-Watcher im Worker liest `"role":"user"`-Lines und matcht `/rename ` und `/coord-rename `. Bridge hat denselben Watcher als Defense-in-Depth. Beide schreiben idempotent — kein Konflikt. **Noch nicht praktisch getestet** (braucht echte claude.exe-Sitzung).

6. **Hook-Conflict-Block**: PreToolUse Hook liest die "aktuelle short_id" via Fallback "neueste active session". E2E-Test pruefen ich nicht, weil ohne echte cc-yolo-Sitzung schwer zu simulieren ist.

7. **NSSM-Service `DT - cc-sessions-coord`** laeuft, baut neuer Worker, `/health` gruen. Service-Account-Permissions (ACL fuer nssm stop/start) waren bereits gepatched.

---

## Naechste Schritte (Morgen frueh zu pruefen)

1. **Echter Multi-Session-Test:** zwei `cc-yolo Alice` / `cc-yolo Bob` in zwei wt-Tabs starten, `coord_inject` via MCP-Tool in Alice ausrufen, Bob sollte die Inject-Nachricht im Chat sehen.
2. **Hook-short_id-Erkennung fixen:** PID-basierte Lookup einbauen.
3. **Hook in `~/.claude/hooks/session-coord/*.sh`-Wrappern verdrahten:** die alten Wrapper rufen `pwsh ... pre-tool-use.ps1` auf — pruefen ob die alten Wrapper auf den neuen Pfad `cc-sessions-coord/scripts/hooks/*.ps1` umzustellen sind.
4. **`~/.claude.json` MCP-Eintrag mit expliciten env**: falls Multi-Session-Test in Punkt 1 zeigt dass `CCSC_SESSION_NAME` nicht ankommt.
5. **PR-Review der Branch `feat/db-centric-greenfield`** vor Merge auf master.
