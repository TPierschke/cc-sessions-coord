# Sink-Idempotenz-Pflichttest — 2026-05-07

**Frage:** Deduplizieren Hindsight + Shodh serverseitig auf einen stabilen Client-Identifier, sodass doppelte POSTs bei Worker-Retry oder Hook-Replay keine Duplikate erzeugen?

**Antwort:** Ja. Beide Sinks sind idempotent — Reconciliation-Loop wird zur optionalen Safety-Net-Komponente, nicht zur Pflicht.

## Hindsight (MCP-HTTP, `http://127.0.0.1:8888/mcp/default`)

**Transport:** Streamable-HTTP mit Server-Sent-Events. Worker muss MCP-JSON-RPC sprechen, kein REST.

**Tool:** `retain` mit Schema:

| Feld | Typ | Pflicht | Bemerkung |
|------|-----|---------|-----------|
| `content` | string | ja | Der zu speichernde Text |
| `context` | string | nein | Default `"general"` — wir setzen `"cc-sessions-coord"` |
| `document_id` | string | nein | **Idempotenz-Key** |
| `tags` | array<string> | nein | |
| `metadata` | object<string,string> | nein | |
| `timestamp` | string | nein | |

**Test:**

```text
POST tools/call retain (content=X, document_id=Y) → operation_id=A, status=accepted
POST tools/call retain (content=X, document_id=Y) → operation_id=B, status=accepted
GET  list_memories(q=...)                        → total=1, chunk_id=default_Y_0
```

**Befund:** Operations sind unterschiedlich (jeder Call legt ein eigenes Async-Task-Objekt an), aber das resultierende Memory ist dasselbe — `chunk_id` enthält das `document_id`. **`document_id` ist serverseitiger Idempotenz-Anker.** Worker muss `document_id = event_id` (UUIDv5) setzen.

**Asynchronizität:** `retain` antwortet sofort mit `accepted` + `operation_id`, das Memory selbst ist erst ~4 s später in `list_memories` sichtbar. Für unseren Loop unkritisch (fire-and-mark-ok), für Reconciliation-Test relevant.

## Shodh (REST, `http://127.0.0.1:3030`)

**Auth-Header:** `X-API-Key: <SET_VIA_ENV>` (nicht `Authorization: Bearer` wie ursprünglich im Plan).

**Endpoint:** `POST /api/remember`. Pflichtfelder:
- `user_id` (string)
- `content` (string, mindestens 10 Zeichen, kein Em-Dash/U+2014 — Parser-Bug, ASCII-Strich verwenden)

**Antwort:** `{"id": "<uuid>", "success": true}`.

**Test:** Zwei identische POSTs mit demselben `(user_id, content)` lieferten beide `id: 5e116074-f03f-4009-8d23-55490d1c7e08`. Server dedupliziert auf content-Hash (vermutlich pro `user_id`).

**Konsequenz für Worker:** `user_id = "cc-sessions-coord"` (oder pro Maschine), `content` = Memory-Inhalt. Eine zusätzliche `event_id` als Idempotenz-Key ist nicht nötig — Shodh dedupliziert automatisch. Für Worker-Retries ist das ausreichend.

## Folgen für die Spec

| Bereich | Original-Plan | Realität nach Test | Anpassung |
|---------|---------------|-------------------|-----------|
| Hindsight-Aufruf | REST POST `/v1/retain` mit `Authorization: Bearer` | MCP-JSON-RPC `tools/call retain` mit `document_id` | Worker braucht MCP-Client (Stateless-Mode reicht, jeder Call ein eigener HTTP-Request) |
| Shodh-Aufruf | REST POST `/v1/memory/remember` mit `Authorization: Bearer` | REST POST `/api/remember` mit `X-API-Key` und `user_id`-Pflichtfeld | Plan-Konstanten korrigieren |
| Reconciliation-Loop | Pflicht falls Sinks nicht idempotent | Beide idempotent → optional | Implementation Phase 2, vorerst weglassen |
| Idempotenz-Schema-Feld | UUIDv5 als `event_id` Pflicht | Bleibt — Hindsight nutzt es als `document_id`, Worker-DB nutzt es als PK | Unverändert |

## Cleanup-Notizen

Die Test-Memories (`document_id = cc-sessions-coord-probe-doc-20260507a` in Hindsight, `5e116074-…` in Shodh) wurden bewusst **nicht** gelöscht — sie sind der dokumentarische Beleg dieses Tests. Falls sie beim späteren echten Roll-out stören, manuell mit `delete_memory` (Hindsight) bzw. `POST /api/forget` (Shodh) entfernen.
