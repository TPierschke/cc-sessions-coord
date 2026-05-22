---
name: coord-reply
description: Use when user types `/coord-reply` oder `/coord reply`. Antwort auf eine empfangene Channel-Injection einer anderen Session. Bevorzuge direkt `/coord pong <id>` (fuer alerts) oder `/coord respond <id>` (fuer exec_dialogs).
---

# Coord-Reply (Alias / Pointer)

Dieser Skill ist ein Pointer auf den Haupt-Skill `coord`. Funktionalitaet:

- **Antwort auf alert** (kind=alert): nutze `/coord pong <injection-id> "<text>"` → MCP-Tool `mcp__ccsc-channel__coord_pong`.
- **Antwort auf exec_dialog** (kind=exec_dialog): nutze `/coord respond <injection-id> "<text>"` → MCP-Tool `mcp__ccsc-channel__coord_exec_response`.

Welcher Kind vorliegt, steht in der empfangenen `<channel>`-Nachricht im `kind`-Attribut. Bei Unsicherheit: ueber `coord_info_session` die Original-Injection nachschlagen.

Vollstaendige Doku im Skill `coord` (`packaging/claude-code/skills/coord/SKILL.md`).

**Verworfen:** Das alte `coord-subcommands.ps1 reply`-Pattern ist abgeloest — kein PowerShell-Script mehr aufrufen.
