# Channel wire contract (Worker ↔ Bridge)

English-only canonical contract for **P4 channel routes** and **P5 admin rotation**.  
Implementation source: [`CoordEndpoints.cs`](../../src/CcSessionsCoord.Worker/Endpoints/CoordEndpoints.cs), [`AdminEndpoints.cs`](../../src/CcSessionsCoord.Worker/Endpoints/AdminEndpoints.cs), [`ChannelConnectionRegistry.cs`](../../src/CcSessionsCoord.Worker/Channel/ChannelConnectionRegistry.cs), bridge under [`src/CcSessionsCoord.ChannelBridge/`](../../src/CcSessionsCoord.ChannelBridge/).

## Base URL

- Default: `http://127.0.0.1:7733` (bridge override: `CCSC_WORKER_BASE`).

## Shared secrets

| Secret | File / header | Notes |
|--------|----------------|-------|
| Channel token | `%ProgramData%\CcSessionsCoord\channel-token.txt` (override `CCSC_CHANNEL_TOKEN_FILE`) | Sent only as header `X-Coord-Channel-Token`. Query `?token=` is rejected with **400**. |
| Admin token | `%ProgramData%\CcSessionsCoord\admin-token.txt` (override `CCSC_ADMIN_TOKEN_FILE`) | Header `X-Admin-Token` for admin routes. |

## JSON naming

- HTTP JSON uses **snake_case** (global serializer on the worker).

---

## `GET /coord/sessions/by-pid`

**Purpose:** Resolve `(pid, pid_start_time)` → `session_id` for the bridge.

The worker only considers rows where **`session_client` is `claude_code`** (PID lookup is for Claude Code only). IDE sessions (e.g. `cursor`) must register with an explicit `session_id` and do not participate in by-pid resolution.

**Query:** `pid` (int), `pid_start_time` (long, Unix ms).

**Headers:** `X-Coord-Channel-Token` (required).

**Responses:** `200` `{ session_id, started_at }`, `401`, `404`.

---

## `GET /coord/channel/stream` (SSE)

**Headers (required unless noted):**

| Header | Required | Meaning |
|--------|------------|---------|
| `X-Coord-Channel-Token` | yes | Channel shared secret. |
| `X-Coord-Session-Id` | yes | Target session UUID. |
| `Last-Event-ID` | no | Last processed `event_seq` for replay (default `0`). |
| `X-Coord-Bridge-Epoch` | no | Informational only (logging); not authoritative. |
| `X-Coord-Force-Takeover` | no | If `true`, may evict an existing connection after cool-down. |

**Responses before stream:** `401`, `400` (token in query), `409` with JSON `{ error, retry_after_ms }` (cool-down), `409`/`Conflict` for `already-active` / `connect-failed`, `200` with `text/event-stream`.

**First SSE event:** `event: hello` with JSON `{ connection_id, server_time }`. `connection_id` is **server-issued**; all `POST /coord/channel/ack` bodies must use this id while the connection is active.

**Subsequent events:**

| `event` | `id` line | `data` (JSON, snake_case where applicable) |
|---------|-----------|-----------------------------------------------|
| `inject` | `event_seq` when known | Worker injection payload (see below). |
| `ping` | — | `{}` keep-alive (~5s idle). |
| `token-rotated` | — | `{ "at": "<ISO-8601 UTC>" }` — emitted **before** rotation disconnect when admin rotates the channel token. |
| `bye` | — | `{ "reason": "rotated" }` — stream ends after this; bridge must reconnect with new token. |

**Rotation semantics (P5 + stream):**

1. Client calls `POST /coord/admin/rotate-channel-token` with valid admin token.
2. Worker writes a new channel token file and, for **each** active SSE connection, delivers **in order**: `token-rotated`, then `bye` (`reason: rotated`), then cancels that connection’s internal token so the stream ends.
3. Bridge: on `token-rotated` set internal flag; on `bye` close SSE; jitter 500–1500 ms; re-read token file (up to 3 reads if unchanged); reconnect with `Last-Event-ID` from dedupe / replay state.

**Eviction (takeover):** Existing connections may be cancelled without `token-rotated`/`bye` when superseded by another client with `X-Coord-Force-Takeover: true` after cool-down (bridge should treat as disconnect and reconnect).

---

## `POST /coord/channel/ack`

**Headers:** `X-Coord-Channel-Token`, `X-Coord-Session-Id`, `Content-Type: application/json`.

**Body (snake_case):** `{ "injection_id": <long>, "connection_id": "<guid>" }`

**Rules:** Must match the **current** active `connection_id` for that session; otherwise **403**. Updates `delivered_at` when eligible; idempotent **200** `{ acked: "set" | "idempotent" }`.

---

## Inject SSE payload (Worker → Bridge)

Bridge validates then maps to MCP `notifications/claude/channel`. Worker fields include at least:

- `injection_id` (long)
- `source_session_id`, `target_session_id`
- `inject_text` (maps to MCP `payload`)
- `priority`, `kind`, `created_at`, `expires_at`, `event_seq`

Unknown `kind` values should be normalized to a safe MCP enum client-side.

---

## `POST /coord/admin/rotate-channel-token` (P5)

**Headers:** `X-Admin-Token` (must match admin token file).

**Effect:** Rotates channel token on disk; evicts all SSE connections with `token-rotated` + `bye` as above; returns **200** `{ rotated_at, evicted, new_token_preview }`.

---

## Versioning

Bump this document when any header, event name, or JSON field in the rows above changes.
