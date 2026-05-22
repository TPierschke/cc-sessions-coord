---
title: cc-sessions-coord — Claude Code Channel-Koordination
date: 2026-05-20
status: freigegeben (Channel-Pfad verifiziert; Legacy-/coord-Migration offen)
version-bridge: 0.3.11
basis:
  - docs/spec/2026-05-14-db-centric-architecture-spec.md
  - .cursor-notes/channel-mcp-tool-contract.md
ziel-maschinen: <YOUR-HOST>, NBK-VO
---

# Claude Code — Inter-Session-Koordination (Spec)

## 1. Zweck

Parallele **Claude Code**-Sitzungen auf einer Workstation sollen sich **ohne Datei-Races** unterhalten können: Aufträge, Fragen, Notaus, Konflikt-Hinweise. Der **kanonische Pfad** für neue Arbeit ist:

1. Sitzung starten mit **`cc-yolo <Name>`** (setzt `CCSC_SESSION_NAME`, lädt Channel-MCP).
2. Nachrichten senden/empfangen über **MCP-Tools** der Bridge (`ccsc-channel`).
3. Zustellung an die Empfänger-Sitzung über **`notifications/claude/channel`** (sofort, kein Warten auf den nächsten User-Prompt).

Diese Spec definiert **Verhalten, Tool-Auswahl und Betrieb** für Menschen und Agenten. Sie ersetzt nicht die DB-Architektur-Spec (Postgres, Trigger, Hooks) — ergänzt sie um den **Channel-Produktvertrag**.

**Geltungsbereich:** Claude Code mit Development-Channels + `server:ccsc-channel`.  
**Außerhalb:** Cursor/OpenCode ohne Bridge (eigene Touch-Registrierung, kein `<channel>`).

---

## 2. Zielbild („fertig“ für CC)

| Kriterium | Soll |
|-----------|------|
| Push-Latenz | Inject → `<channel>` in Empfänger-Session typisch **&lt; 100 ms** (lokal PG) |
| Ziel-Auflösung | `target` bevorzugt **`session_name`** (z. B. `T92`), nicht kopierte Hex-`short_id` |
| Bridge-Neustart | Neuer `short_id` pro Name; alte NOTIFY-Channels **tot** (V002 + `resolveTarget`) |
| Dialog-Disziplin | `coord_exec_response` / `coord_pong` nur nach **`coord_exec_dialog`** (oder Tool mit `expects_reply`) |
| Einseitige FYI | `coord_info` oder **Schweigen** — kein erzwungenes `coord_exec_response` |
| Legacy `/coord` | Dokumentiert als **deprecated**; Skill-Migration in Phase 2 (siehe §8) |
| Abnahme | `npm run verify:all` grün; manueller Ping-Pong zwischen zwei cc-yolo-Namen |

---

## 3. Architektur (Ist)

```
Thomas (User)
    │
    ├─ cc-yolo T92 ──► claude.exe + MCP ccsc-channel (stdio Bridge)
    │                      │
    │                      ├─ LISTEN c_i_<short_id>
    │                      ├─ coord_* Tools → INSERT coord.injections
    │                      └─ NOTIFY → claim → notifications/claude/channel
    │
    └─ (parallel, deprecated) /coord Skill → coord-subcommands.ps1
           → HTTP Worker :7733 → Pull-Hook UserPromptSubmit (nur ohne CCSC_YOLO)
```

| Komponente | Pfad / Dienst |
|------------|----------------|
| Wrapper | `scripts/cc-yolo.ps1` |
| Bridge | `src/CcSessionsCoord.ChannelBridge/` (`npm run build`) |
| MCP-Name in Claude | `server:ccsc-channel` → `node …/dist/index.js` in `~/.claude.json` |
| Postgres | Schema `coord`, DB `cc_sessions_coord`, Migration **V001 + V002** |
| Worker :7733 | Legacy-HTTP + Dashboard; **nicht** Channel-Zustellung |
| Hooks (Konflikt) | `scripts/hooks/` + `~/.claude/hooks/session-coord/` (Pull-Pfad) |

**Umgebungsvariablen (Bridge):** `CCSC_SESSION_NAME` (Pflicht für sinnvolle Registrierung), `CCSC_PG_*` / Connection-String wie in Bridge-`loadConfig()`.

---

## 4. Session-Identität und Targeting

### 4.1 Namen

- **`session_name`**: menschlicher Name aus `cc-yolo` / `--name` (z. B. `T92`, `WebOps MS1 3`).
- **`short_id`**: 8 Zeichen Hex, von Postgres bei Registrierung vergeben.
- **`claude_session_id`**: UUID aus JSONL; bei Resume mit UUID bleibt **dieselbe** `short_id` (V002 UPDATE-Pfad).

### 4.2 Regeln für `target` in allen `coord_*`-Tools

1. **Bevorzugt** `session_name` (case-insensitive Treffer auf aktive Zeile).
2. **Hex-Präfix** nur wenn eindeutig; nach Bridge-Neustart **nie** alte ID aus Chatverlauf recyceln.
3. **`resolveTarget`**: Wenn `target` wie Hex aussieht, aber eine **aktive** Session mit gleichem `session_name` existiert, wird auf deren **aktuellen** `short_id` umgeleitet (Schutz vor stale NOTIFY).

### 4.3 V002 — Supersede bei Re-Register

Ohne `claude_session_id`: vor INSERT werden alle **aktiven** Zeilen mit gleichem `session_name` auf `ended` gesetzt. Verhindert Zustellung an `c_i_<alter_short_id>` nach Prozess-Neustart.

### 4.4 cc-yolo

| Aufruf | `CCSC_SESSION_NAME` | `--name` |
|--------|---------------------|----------|
| `cc-yolo Name` | gesetzt | ja |
| `cc-yolo -r <term>` | gesetzt (= term) | nein |
| `cc-yolo -c` | unverändert / leer | nein |

Flags immer: `--dangerously-skip-permissions`, `--dangerously-load-development-channels`, `server:ccsc-channel`.

Bei `CCSC_YOLO=1`: Pull-Hook `hook-user-prompt-submit.ps1` **beendet sofort** — nur Channel-Zustellung zählt.

---

## 5. MCP-Tool-Vertrag (Normativ)

### 5.1 Auswahl-Matrix

| User-Intent | Tool | `kind` in DB | `expects_reply` | Empfänger antwortet mit |
|-------------|------|--------------|-----------------|-------------------------|
| Sofort ausführen, keine Rückfrage | `coord_exec` | `exec` | false | optional `coord_exec_reply` / `ack` im Chat |
| Auftrag **mit** Antwortpflicht | `coord_exec_dialog` | `exec_dialog` | **true** | `coord_exec_response` oder `coord_pong` |
| Antwort auf offenen Dialog | `coord_exec_response` | `exec_response` | — | nur mit `dialog_id` + `reply_to_injection_id` |
| Kurz-Ack / PONG | `coord_pong` | `exec_response` | — | wie response; erzeugt ggf. `dialog_id` |
| FYI, keine Antwort nötig | `coord_info` | `info` | false | **nichts** (Schweigen ok) |
| Notbremse eine Session | `coord_alert` / `coord_stop` | `alert` / `stop` | kontextabhängig | siehe Tool-Beschreibung |
| Notbremse alle | `coord_notaus_all` | `notaus` | — | — |
| Broadcast | `coord_broadcast_*` | variiert | meist false | — |
| Discovery | `coord_whoami`, `coord_neighbours`, `coord_all`, … | — | — | — |

### 5.2 Harte Regeln (Agenten)

1. **`coord_exec_response` nur nach `coord_exec_dialog`** (oder nach Injection mit `expects_reply=true` und passender `injection_id`).  
   **Verboten:** `coord_exec_response` nach `coord_exec`, `coord_info`, User-Slash `/coord inject`, oder reinem Vorschlag ohne Dialog-ID.

2. **Schweigen ist gültig:** Kein offener Dialog → keine Antwort erzwingen (Beispiel: opencode `--pure`-FYI — MCP hat ~12 Tools, 206-Limit betrifft GUI-Pfad).

3. **Ziel immer per Name:** `coord_pong(target="T92", …)` nicht `target="0229d248"` aus alter Nachricht.

4. **Channel-Inhalt:** Body = Klartext-`payload` (JSON in `inject_text` wird geparst — `parseInjectBody`). Meta enthält `injection_id`, `source_short_id`, `expects_reply`, ggf. `reply_to_injection_id`.

5. **Nach Erledigung:** Empfänger quittiert im **eigenen** Turn (nicht automatisch bei idle) — für Pull-Legacy zusätzlich `/coord ack <id>`.

### 5.3 Parameter (Dialog-Paar)

**Senden (A → B):**

```text
coord_exec_dialog(
  target="B",
  payload="…",
  dialog_id?   // optional; Bridge vergibt UUID wenn fehlt
)
→ returns { dialog_id, injection_id, target_short_id, ok }
```

**Antworten (B → A):**

```text
coord_exec_response(
  target="A",
  dialog_id="<von Dialog>",
  reply_to_injection_id=<injection_id aus meta>,
  payload="…",
  status? = ok | error
)
```

**Äquivalent kurz:** `coord_pong(target, reply_to_injection_id, payload, dialog_id?)` → schreibt ebenfalls `exec_response`.

### 5.4 Registrierte Tools (Bridge 0.3.11)

**Discovery:** `coord_whoami`, `coord_health`, `coord_info_self`, `coord_info_session`, `coord_neighbours`, `coord_all`

**Messaging / Ausführung:** `coord_exec`, `coord_exec_dialog`, `coord_exec_response`, `coord_exec_reply`, `coord_info`, `coord_alert`, `coord_stop`, `coord_alertstop`, `coord_pong`, `coord_start_pingpong`

**Broadcast:** `coord_broadcast_status`, `coord_broadcast_ping`, `coord_broadcast_sync`

**Notaus:** `coord_notaus`, `coord_notaus_all`

MCP-`instructions` (einmalig im System-Prompt): Channel wie Coworker-Interrupt behandeln; bei `expects_reply` mit `coord_pong` / `coord_exec_response` antworten.

---

## 6. Zustellungs-Pipeline

1. Tool `enqueueToTarget` → `INSERT coord.injections` → Trigger `pg_notify('c_i_<target_short_id>', id)`.
2. Empfänger-Bridge: LISTEN → `claim_batch` (SKIP LOCKED) → `renderInjection` → `notifications/claude/channel`.
3. Claude rendert `<channel>…</channel>` im Kontext der **Empfänger**-Session.

**Fehlerbild „Tool ok, kein Channel“:** NOTIFY ging an **alten** `short_id` → §4.2/4.3 prüfen; Ziel per **Name** erneut senden.

**Logging:** `~/.claude/logs/cc-sessions-coord.log` — Einträge `mcp-channel-push-ok` / Fehlerpfade.

---

## 7. Betrieb (Checkliste)

### 7.1 Neue cc-yolo-Session

```powershell
cd <projekt>
cc-yolo T93
```

Nach Code-Änderung an der Bridge:

```powershell
cd src/CcSessionsCoord.ChannelBridge
npm run build
```

### 7.2 MCP in `~/.claude.json` (Beispiel)

```json
"ccsc-channel": {
  "command": "node",
  "args": ["C:/Users/.../cc-sessions-coord/src/CcSessionsCoord.ChannelBridge/dist/index.js"],
  "env": {}
}
```

`env` leer ist ok, wenn `CCSC_SESSION_NAME` vom Parent (`cc-yolo`) gesetzt wird.

### 7.3 Smoke

```powershell
cd src/CcSessionsCoord.ChannelBridge
npm run verify:all
```

Manuell: zwei Terminals `cc-yolo T92` / `cc-yolo T93` → `coord_exec_dialog` / `coord_pong` (siehe `scripts/pingpong-t86-t87.ps1` als Vorlage).

---

## 8. Legacy `/coord` (Parallel-Stack, Deprecation)

| Aspekt | Legacy | Kanonisch (diese Spec) |
|--------|--------|-------------------------|
| UI | Skill `~/.claude/skills/coord/SKILL.md` → `coord-subcommands.ps1` | MCP `coord_*` |
| Transport | HTTP Worker :7733 | Postgres NOTIFY + Channel |
| Empfang | `UserPromptSubmit`-Hook (`<coord-exec>`) | `<channel>` |
| `exec` | `/coord exec` → `kind=exec` Pull | `coord_exec` oder `coord_exec_dialog` Push |
| Skill-Doku | unvollständig (fehlt z. B. `exec`) | diese Spec §5 |

**Migrationsphasen (empfohlen):**

| Phase | Inhalt |
|-------|--------|
| **0 (jetzt)** | Neue Features nur noch MCP; `/coord` nur Wartung |
| **1** | Skill `coord` auf Tool-Matrix §5 mappen; `/coord exec` → Hinweis `coord_exec_dialog` |
| **2** | Pull-Hook für cc-yolo-Sessions abschalten (bereits `CCSC_YOLO`); für Nicht-yolo entscheiden |
| **3** | `05-session-coord.md` / SQLite-Doku streichen; Worker :7733 auf Dashboard/Health reduzieren |

**Nicht migrieren 1:1:** `/coord ack` (Pull-Re-Delivery) — Channel hat kein Re-Inject bis Quittierung in DB; ggf. später `coord_ack`-Tool.

---

## 9. Peer-IDEs und andere Agenten

| Client | Registrierung | Messaging |
|--------|---------------|-----------|
| Claude Code (cc-yolo) | Bridge `ccsc_register_session` | MCP + Channel |
| Cursor | geplant: `scripts/ccsc-cursor-touch.ps1` → `session_client=cursor` | kein Channel; Coord-DB-Sichtbarkeit |
| OpenCode / Codex | manuell / eigene MCP | FYI nur bei Dialog; sonst `coord_info` oder schweigen |

Cross-Tool-Regel aus Produktbetrieb: **Kein `coord_exec_response` auf einseitige Cursor-Injections** (z. B. `--pure`-Analyse ohne `coord_exec_dialog`).

---

## 10. Nicht-Ziele (bewusst offen)

- Automatische Antwort der Empfänger-Sitzung **ohne** User-Turn (idle → kein Tool-Call).
- SSE `/coord/watch` (Legacy-Stub 501).
- Vollständiger Ersatz des Worker-HTTP-API in Phase 0.
- Episodic-Memory-Wrap (Port 14014), Steel-Browser, Mail-NSSM — eigene Specs/Stränge.

---

## 11. Abnahme

| Test | Erwartung |
|------|-----------|
| `npm run verify:all` | grün nach `build` |
| T92 → T93 `coord_exec_dialog` | T93 sieht Channel mit PONG-Hinweis |
| T93 `coord_pong` → T92 | T92 sieht `exec_response` im Channel |
| Bridge-Neustart + gleicher Name | Ping mit **Name** `T92`, nicht alter Hex-ID, trifft |
| `coord_exec_response` ohne vorherigen Dialog | Agent unterlässt (Review/Handover) |
| Legacy `/coord inject` in cc-yolo-Session | Kein doppeltes Pull (CCSC_YOLO) |

---

## 12. Referenzen

| Dokument | Inhalt |
|----------|--------|
| `docs/spec/2026-05-14-db-centric-architecture-spec.md` | Postgres, Hooks, Worker-Rolle |
| `.cursor-notes/channel-mcp-tool-contract.md` | Kurz-Vertrag Post-/compact |
| `src/CcSessionsCoord.ChannelBridge/src/index.ts` | Tool-Implementierung (Source of Truth) |
| `src/CcSessionsCoord.ChannelBridge/src/render.ts` | Channel-Rendering |
| `migrations/V002__register_supersede_active_name.sql` | Supersede-Regel |

---

## Änderungshistorie

| Datum | Änderung |
|-------|----------|
| 2026-05-20 | Erstversion: Channel-Vertrag, Tool-Matrix, Legacy-Migration, Abnahme |
