---
name: coord
description: Use when user types `/coord`, fragt nach Session-Koordination, parallelen Claude-Sessions, Konflikten zwischen Sessions, Inter-Session-Messaging, oder einen der Subcommands `alert`/`ask`/`pong`/`respond`/`ack`/`status`/`list`/`cancel`/`rewrite` nennt. Trigger: "coord", "injection", "konflikt mit anderer session", "session status", "andere session benachrichtigen", "ping session", "alert session", "ask session".
---

# Session-Coordination Skill (ccsc-channel)

User-Interface fuer Inter-Session-Koordination. Alle Subcommands rufen direkt MCP-Tools von `mcp__ccsc-channel__*` auf — KEIN PowerShell-Script mehr. Das alte `coord-subcommands.ps1`-System ist verworfen (siehe Spec `docs/spec/2026-05-20-coord-skill-migration-spec.md` im cc-sessions-coord-Repo).

## Subcommands

| `/coord <sub>` | MCP-Tool | Bedeutung |
|---|---|---|
| `status` | `coord_info_self` + `coord_all status=active` | Eigene Identitaet + alle aktiven Peers (mit `last_seen`-Spalte). |
| `alert <target> "<text>" [prio]` | `coord_alert` | Fire-and-forget Nachricht, keine Antwort erwartet. |
| `ask <target> "<frage>"` | `coord_exec_dialog` | Frage mit erwarteter Antwort. Generiert dialog_id automatisch. |
| `cancel <injection-id>` | `coord_alertstop` | Eigene offene Alert-Injection zurueckziehen. |
| `pong <id> "<text>"` | `coord_pong` | Antwort auf empfangenen **alert** (kind=alert). |
| `respond <id> "<text>"` | `coord_exec_response` | Antwort auf empfangenen **exec_dialog** (kind=exec_dialog). |
| `ack <id>` | `coord_pong` mit payload `"ack"` | Convenience: kurze Empfangsbestaetigung fuer alert. |
| `rewrite <id> "<neuer text>"` | `coord_alertstop <id>` + neuer `coord_alert` | ccsc hat kein natives Rewrite; Skill kombiniert zwei Calls. |
| `list` | `coord_neighbours` | Nachbar-Sessions inkl. offener Threads. |

**Entfaellt** (nicht aequivalent in ccsc): `received` (keine Postbox-API), `on`/`off` (kein Session-lokaler Kill-Switch — `coord_notaus` waere global).

**Alte Aliase** (Muscle-Memory): `inject` ohne Flag → `alert`. `inject --dialog` → `ask`. `reply` → entweder `pong` (alert) oder `respond` (exec_dialog), je nach Original-kind. Bei Unsicherheit: kind aus der Channel-Inject-Nachricht ablesen.

## Target-Resolution

Target-Argument akzeptiert:

1. **Short-ID** (z.B. `a680c46b`) — immer eindeutig, bevorzugt.
2. **Session-Name** (z.B. `PenTest`) — nur wenn EINDEUTIG via `coord_all` (1 Treffer).
3. **Bei Mehrdeutigkeit (z.B. 3 aktive Sessions namens "T3"):** Skill bricht ab und gibt Kandidatenliste mit Short-IDs aus. KEIN implizites First-Match.

Beispiel-Abbruchmeldung:
```
Target "T3" ist nicht eindeutig — 3 Treffer:
  - 81dcde06  T3  cwd=dthbApps/dtWebOps  started=2026-05-14T10:53
  - 5e20bfd4  T3  cwd=dthbApps/dtWebOps  started=2026-05-14T10:45
  - 07f830fb  T3  cwd=dthbApps/dtWebOps  started=2026-05-14T10:43
Verwende eine Short-ID.
```

## Beispiele

```text
/coord status
```
Tool-Call: `mcp__ccsc-channel__coord_info_self` + `mcp__ccsc-channel__coord_all status=active`.

```text
/coord ask PenTest "Hast du wsm_ReadOnly-Rechte verifiziert?"
```
Tool-Call: `mcp__ccsc-channel__coord_exec_dialog target="a680c46b" payload="Hast du wsm_ReadOnly-Rechte verifiziert?" dialog_id="<auto>"`.

```text
/coord pong 96 "ack, ENV-Var heisst CLAUDE_ADMIN_CRED"
```
Tool-Call: `mcp__ccsc-channel__coord_pong target="<source_short_id-aus-Inject-96>" reply_to_injection_id=96 payload="..." status=ok`.

## API-Contract

- `coord_alert`/`coord_exec_dialog` liefern `injection_id` und `target_short_id` **synchron** im Tool-Response. Diese IDs sofort in Antwort an User durchreichen.
- `coord_pong`/`coord_exec_response` brauchen `reply_to_injection_id` und `target` (Source-Short-ID aus der empfangenen Channel-Nachricht — bei `source_short_id=""` ist die Antwort technisch nicht moeglich).
- Bei MCP-Tool-Fehler: Fehlermeldung **unveraendert** an User durchreichen, keine Skill-eigene Retry-Logik.

## Verwandtes

- Migration-Spec: `docs/spec/2026-05-20-coord-skill-migration-spec.md` (cc-sessions-coord)
- Channel-Spec: `docs/spec/2026-05-20-claude-code-channel-coord-spec.md`
- MCP-Proxy endpoints: configure per host (see your local ops briefings; not in this repo).
- Altes (verworfenes) PS-System: `~/.claude/scripts/session-coord.archived-*` — NICHT aufrufen.
