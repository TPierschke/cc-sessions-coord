# Channel delivery trace briefing (2026-05-17)

Operator brief for the next inject-debug round after bridge **0.3.8** (push-trace JSONL).

Canonical adoption notes: see `docs/spec/2026-05-20-claude-code-channel-coord-spec.md` and repo history before public scrub.  
Background: `docs/spec/2026-05-14-briefing.md`.

## Before testing

1. `npm run build` in `src/CcSessionsCoord.ChannelBridge/`
2. **Restart every Claude session** that should receive pushes (`cc-yolo` tabs) so they load the new bridge subprocess.
3. In each session once: `/mcp` reconnect `ccsc-channel` (or restart with `--dangerously-load-development-channels server:ccsc-channel`).

## Trace logs (0.3.8+)

| File | Purpose |
|------|---------|
| `~/.claude/channels/ccsc-channel-bridge/bridge-<bridgePid>.log` | Normal bridge events |
| `~/.claude/channels/ccsc-channel-bridge/bridge-<bridgePid>-push-trace.jsonl` | **Full push stream** — NOTIFY payload, claimed row IDs, exact MCP `notifications/claude/channel` params |

Correlate with Claude transcript:

- T86 JSONL example: `~/.claude/projects/C--Users-thomas-pierschke-source-repos/376f53f1-75c0-4c1c-80ca-9644042fe42c.jsonl`
- Match `claimed_ids` / `notify_payload` in push-trace vs `<channel … injection_id=…>` lines in JSONL.

## Known findings (2026-05-17 evening)

- **NOTIFY payload is correct** in bridge log (`notify payload 24` → `drain ids [24]`).
- **T88 idle (0 tokens)** often shows **no JSONL channel line** even when bridge logs `notification-rendered-sent`.
- **T86 activity at #24 time** was actually **HTTP ping-pong at 02:52:23** and tool output for **#23 at 02:52:40** — not mis-routed NOTIFY for #24.
- Two delivery paths: **Postgres NOTIFY + claim_batch** vs **HTTP POST /inject** (port 45777 per session, or next free port).

## peers-mcp adoption status (snapshot)

| Item | Status |
|------|--------|
| Stale cleanup 30s (Worker) | partial — PidWatchdog 60s, no `bridge_pid` |
| `set_summary` + V002 `summary` | open |
| Scope filter on status | partial — `coord_neighbours` cwd only |
| `git_root` + cc-yolo ENV | open |
| 60s poll fallback | open |
| Heartbeat 15s | open (still 30s) |
| Doppel-Push (legacy+rendered) | open |
| Debug fetch :7915 | fixed in current branch |
| `bridge_pid` in list | fixed |

## Next implementation (after trace round)

1. `ccsc_claim_by_id(short, id)` — honor NOTIFY payload, not only FIFO batch
2. `coord_pull_pending` MCP tool (Abholauftrag / pull when idle)
3. Optional 60s `claimBatch` poll fallback
4. peers-mcp table items (V002, stale watchdog, scope, git_root)

## References (open source)

- https://github.com/louislva/claude-peers-mcp
- https://github.com/anthropics/claude-plugins-official (fakechat channel example)
- https://code.claude.com/docs/en/channels-reference
