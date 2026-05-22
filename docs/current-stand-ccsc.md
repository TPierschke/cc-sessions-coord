# cc-sessions-coord — frozen (closure)

**As of:** 2026-05-20 · **Tag:** `v0.3.11-public` · **Public:** https://github.com/TPierschke/cc-sessions-coord

## Done

- Channel MCP **0.3.11** — cross-session live (exec / dialog / pong)
- `/coord` skills → `packaging/claude-code/` (MCP, not PowerShell subcommands)
- Public release: internal hosts/secrets/handover removed from tree
- Legacy: `DT - Coord Watchdog` NSSM removed; worker `DT - cc-sessions-coord` remains

## Specs (public)

- `docs/spec/2026-05-20-claude-code-channel-coord-spec.md`
- `docs/spec/2026-05-20-coord-skill-migration-spec.md`

## Operations (if you resume work)

```powershell
cd src/CcSessionsCoord.ChannelBridge; npm run build
cc-yolo <SessionName>
```

Skills: `packaging/claude-code/README.md` → `~/.claude/skills`

## Known gaps (non-blocking for freeze)

- `scripts/ccsc-cursor-touch.ps1` (optional)
- PG diagnostic scripts `scripts/test-pg-*` (local, not product)
- Dev git history may contain older internal commits — current tree is scrubbed; public repo is single-commit export

**Status: frozen.** New work = new issue / new session, not drive-by commits.
