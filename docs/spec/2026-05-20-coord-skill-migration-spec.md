---
title: Migration der /coord- und /coord-reply-Skills auf ccsc-channel
status: accepted
created: 2026-05-20
accepted_at: 2026-05-20
host: <YOUR-HOST>
author: CortexProblem-Session 84b10f6d
---

# Spec — `/coord` + `/coord-reply` auf ccsc-channel umstellen

## Problem

Die Skills `~/.claude/skills/coord/SKILL.md` und `~/.claude/skills/coord-reply/SKILL.md` riefen das alte PowerShell-Script `coord-subcommands.ps1` auf (Local-SQLite / HTTP Worker Pull). Parallel laeuft **ccsc-channel** (`mcp__ccsc-channel__coord_*`).

## Ziel

`/coord <sub>` ruft direkt ccsc-channel-MCP-Tools auf. **Erledigt 2026-05-20** (Skills in `packaging/claude-code/`).

## Subcommand-Mapping (kanonisch)

| `/coord <sub>` | MCP-Aufruf |
|---|---|
| `status` | `coord_info_self` + `coord_all status=active` |
| `alert <target> "<text>"` | `coord_alert` |
| `ask <target> "<frage>"` | `coord_exec_dialog` |
| `cancel <id>` | `coord_alertstop` |
| `pong <id> "<text>"` | `coord_pong` (alert) |
| `respond <id> "<text>"` | `coord_exec_response` (exec_dialog) |
| `ack <id>` | `coord_pong` payload `"ack"` |
| `rewrite <id> "<neu>"` | `coord_alertstop` + `coord_alert` |
| `list` | `coord_neighbours` |

Entfaellt: `received`, `on`/`off`, `inject` (→ `alert`/`ask` Aliase).

## Decommission (<YOUR-HOST> 2026-05-20)

| Komponente | Aktion |
|------------|--------|
| NSSM `DT - Coord Watchdog` | entfernt |
| `~/.claude/hooks/session-coord/` | → `.archived-2026-05-20` |
| `~/.claude/scripts/session-coord/` | → `.archived-2026-05-20` |
| `settings.json` session-coord hooks | entfernt (Backup `.bak-pre-coord-decom-2026-05-20`) |
| Worker `PidWatchdog` | **bleibt** in `DT - cc-sessions-coord` |

Repo-Hooks (Konflikt-Detection): `scripts/hooks/pre-tool-use.ps1`, `post-tool-use.ps1` (Postgres) — **bleiben**.

## Acceptance

Siehe Original in `C:\dt-knowledge\ops\specs\2026-05-20-coord-skill-migration-spec.md` (Vault-Kopie); alle Punkte 1–6 erfuellt auf <YOUR-HOST>.
