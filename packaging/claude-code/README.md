# Claude Code — Coord install bundle (RC1, migrated 2026-05-20)

**Source of truth** for `/coord` and `coord-reply` skills (ccsc-channel MCP). Synced from CortexProblem migration.

## Install

```powershell
$r = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path  # repo root when run from packaging/claude-code
$h = "$env:USERPROFILE\.claude"
Copy-Item -Recurse -Force "$r\packaging\claude-code\skills\*" "$h\skills\"
```

Merge `docs/setup/ccsc-channel-mcp.fragment.json` into `~/.claude.json`. Sessions: `scripts/cc-yolo.ps1`.

## Nicht mehr installieren

- `~/.claude/scripts/session-coord/` (archiviert)
- `~/.claude/hooks/session-coord/` (archiviert)
- NSSM `DT - Coord Watchdog` (entfernt)

## Docs

| Datei | Inhalt |
|-------|--------|
| `docs/spec/2026-05-20-coord-skill-migration-spec.md` | Slash-Migration |
| `docs/spec/2026-05-20-claude-code-channel-coord-spec.md` | Channel/MCP-Vertrag |
