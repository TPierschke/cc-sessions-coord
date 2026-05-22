# cc-sessions-coord

Central broker for memory sync and inter-session coordination across Claude Code instances.

**Release:** `v0.3.11-rc1` (2026-05-20) — Channel-MCP + Postgres; Spec: `docs/spec/2026-05-20-claude-code-channel-coord-spec.md`.

## Public snapshot — no maintenance

Published **as-is** from a personal setup. It **works for me** on my machines; **your mileage may vary**.

- **No warranty**, **no guarantee**, **no support**, **no help**, and **no commitment** to answer issues, emails, or pull requests.
- You may **fork and change** it for **your own** internal use. If you need something different, **fork** — do not expect upstream changes.
- I do **not** plan to track forks or respond to contributions here.
- **Products or hosted services for others** require a **written license** from the author (see [LICENSE](LICENSE)).

License: [Source Available License v1.0 (2026-05-21)](LICENSE) — internal/professional use OK; no commercial product or third-party hosting without permission.

## Release posture (RC)

Ship targets are **production-grade release candidates**: versioned SQL migrations, rollback scripts where provided, automated tests, smoke/install scripts, and documented operator steps — not a throwaway test rig.

When someone says **“dev”** or **“data loss is fine”**, that only means **permission to apply migrations, re-seed, or reset databases on non-production machines** without extra safeguards — it does **not** mean lowering code quality, skipping migrations, or treating the product as a toy.

## Why

Claude Code sessions are ephemeral — each new session starts fresh with no memory of prior work. **Before**: Each session rediscovered patterns, reran diagnostics, and duplicated solutions. **Now**: A central coordinator captures memories, enables cross-session messaging, and persists insights across session boundaries.

## Architecture

\\\
┌──────────────────────┐
│  Claude Code Session │
│   (multiple)         │
└────────┬─────────────┘
         │ HTTP POST /sync
         │ (memory capture,
         │  command inject,
         │  status query)
         │
      ┌──┴──┐
      │ 7733 │  cc-sessions-coord
      └──┬──┘  (.NET 8 HTTP service)
         │
    ┌────┴────────────────────┐
    │     PostgreSQL DB       │
    │                         │
    │  coord schema:          │
    │  - sessions             │
    │  - commands             │
    │  - locks                │
    │                         │
    │  memory_sync schema:    │
    │  - queue (idempotent)   │
    │  - checkpoints          │
    └────┬────────────────────┘
         │
    ┌────┴─────────────────────┐
    │  Background Sinks        │
    │  - Hindsight MCP         │
    │  - Shodh REST API        │
    │  (persists memories)     │
    └─────────────────────────┘
\\\

**Memory Sync Pipeline**: Session → HTTP POST to /sync → Postgres queue (UUIDv5 deduplication) → Background service → Hindsight MCP + Shodh sinks.

## Features

| Command | Purpose | Type |
|---------|---------|------|
| \/coord inject\ | Inject command into target session | Messaging |
| \/coord exec\ | Execute action in coordinator | Execution |
| \/coord ask\ | Query session status/context | Query |
| \/coord status\ | Retrieve coordinator metrics | Status |
| \/coord pause\ | Pause session coordination | Control |
| \/coord resume\ | Resume paused session | Control |
| \/coord abort\ | Abort running operation | Control |
| \/coord alert\ | Broadcast alert to sessions | Messaging |
| \/coord broadcast\ | Send message to all sessions | Messaging |
| \/coord share\ | Share data between sessions | Sharing |
| \/coord snapshot\ | Capture session state snapshot | Snapshot |
| \/coord lock\ | Acquire distributed lock | Coordination |
| \/coord unlock\ | Release distributed lock | Coordination |
| \/health\ | Health check endpoint | Monitoring |

## Installation

### Prerequisites

- .NET 8 Runtime or SDK
- PowerShell 7+ (pwsh)
- PostgreSQL 18+
- NSSM (Non-Sucking Service Manager) for Windows service

### Steps

1. **Create database user** (as postgres):
   \\\sql
   CREATE ROLE coord_user WITH LOGIN PASSWORD 'strong_password';
   CREATE DATABASE cc_sessions_coord OWNER coord_user;
   GRANT ALL PRIVILEGES ON DATABASE cc_sessions_coord TO coord_user;
   \\\

2. **Clone repository**:
   \\\ash
   git clone https://github.com/TPierschke/cc-sessions-coord.git
   cd cc-sessions-coord
   \\\

3. **Build project**:
   \\\ash
   dotnet build -c Release
   \\\

4. **Apply migrations**:
   \\\ash
   dotnet run --project Services/CoordinationService -- migrate
   \\\

5. **Configure environment** (see Configuration section below).

6. **Install as Windows service**:
   \\\powershell
   nssm install "DT - cc-sessions-coord" "C:\path\to\cc-sessions-coord\bin\Release\net8.0\CoordinationService.exe"
   nssm start "DT - cc-sessions-coord"
   \\\

## Hooks Integration

Sessions post memory captures to the coordinator via HTTP:

\\\ash
curl -X POST http://localhost:7733/sync \\
  -H "Content-Type: application/json" \\
  -d '{
    "sessionId": "abc123",
    "timestamp": "2026-05-12T10:30:00Z",
    "memories": [
      {
        "id": "mem-001",
        "type": "decision",
        "content": "Chose PostgreSQL for async queue",
        "tags": ["architecture"]
      }
    ]
  }'
\\\

## Configuration

Environment variables (configure before service start):

| Variable | Default | Purpose |
|----------|---------|---------|
| \ConnectionStrings__Coordinator\ | localhost | Postgres connection string |
| \ServicePort\ | 7733 | HTTP service port |
| \HindsightUrl\ | http://localhost:8081 | Hindsight MCP endpoint |
| \ShodhUrl\ | http://localhost:8082 | Shodh REST API endpoint |
| \MaxConcurrentSessions\ | 10 | Max simultaneous sessions |
| \SyncQueueCheckIntervalSeconds\ | 5 | Queue polling interval |
| \OperationTimeoutSeconds\ | 30 | Operation timeout (seconds) |

## Testing

Health check:
\\\ash
curl http://localhost:7733/health
\\\

Memory sync:
\\\ash
curl -X POST http://localhost:7733/sync -d '{"sessionId":"test","memories":[]}' -H "Content-Type: application/json"
\\\

Session status:
\\\ash
curl http://localhost:7733/sessions/abc123
\\\

## CLI Examples

Inject command:
\\\ash
/coord inject session-abc "remember: Chosen TypeScript for all new code"
\\\

Broadcast alert:
\\\ash
/coord alert "Database maintenance in 10 minutes" --severity high
\\\

Snapshot session:
\\\ash
/coord snapshot session-abc --output snapshot.json
\\\

## Channel Push (v2.1.80+)

`src/CcSessionsCoord.ChannelMcp/` is a Node.js MCP stdio-server that implements the Claude Code
**Channel push protocol** (Research Preview). It lets the coordinator deliver `coord.injections`
rows directly into a running Claude Code session — Claude reacts without any user keypress.

### Quick start

```bash
cd src/CcSessionsCoord.ChannelMcp
npm install && npm run build
```

Add to `~/.claude/.mcp.json`:

```json
{
  "mcpServers": {
    "ccsc-channel": {
      "command": "node",
      "args": ["<repo-root>/src/CcSessionsCoord.ChannelMcp/dist/index.js"],
      "env": {
        "CCSC_POSTGRES_CONN": "postgresql://coord_user:YOURPASSWORD@localhost:5432/cc_sessions_coord",
        "CCSC_SESSION_ID": "YOUR_SESSION_SHORT_ID"
      }
    }
  }
}
```

Start Claude Code with the development bypass flag (mandatory during Research Preview):

```bash
claude --dangerously-load-development-channels server:ccsc-channel
```

The server polls `coord.injections` every 3 s and pushes pending rows as
`notifications/claude/channel` events. The `inject_text` becomes the body of
`<channel source="ccsc-channel" injection_id="..." kind="..." from="...">`.

See `src/CcSessionsCoord.ChannelMcp/README.md` for full details.

## Known Limitations

1. **Windows-only**: Service wrapper (NSSM) currently supports Windows only.
2. **No auto-migration runner**: Migrations must be run manually; no automatic schema version detection.
3. **/coord watch returns 501**: Live session watch endpoint not yet implemented.
4. **No --remote-control flag**: Remote execution from non-coordinator hosts is not supported.
5. **Single-machine scope**: Coordinator designed for single-workstation use; distributed coordination not supported.

## License

See [LICENSE](LICENSE) (v1.0, 2026-05-21). **Short:** internal use and adaptation for **your own** operations — yes. **Sell, host for others, or ship a product** from a fork — only with **written permission** (thomas.pierschke@icloud.com). This text is the author's stated intent when the repository is made public.

## Maintainer workflow (Thomas only)

- **Develop:** private [cc-sessions-coord-dev](https://github.com/TPierschke/cc-sessions-coord-dev) — full git history preserved.
- **Publish:** public [cc-sessions-coord](https://github.com/TPierschke/cc-sessions-coord) — clean single-commit releases via `scripts/publish-public-clean.ps1`.
- **Local path:** `...\TPierschke\cc-sessions-coord-dev` (junction to the dev clone). Details: `docs/ops/dev-public-repos.md`.

## Author

Thomas Pierschke — personal project; no affiliation stated in this repository.

