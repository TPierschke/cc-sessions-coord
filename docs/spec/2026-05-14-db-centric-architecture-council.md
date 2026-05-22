# Council-Review: cc-sessions-coord — DB-zentrierte Neuarchitektur

**Datum:** 2026-05-14
**Reviewer:** OpenAI `gpt-5`, xAI `grok-4`, Anthropic `claude-opus-4-7` / `claude-opus-4-5` (beide leere Antwort — siehe Hinweis)
**Status:** Vor-Implementierungs-Review, grüne Wiese, alte DB-Daten werden verworfen

> **Hinweis Anthropic-Ausfall:** Beide Anthropic-Modelle (`claude-opus-4-7` und `claude-opus-4-5-20251101`) lieferten via `mcp__opencode__opencode_fire` eine leere Assistant-Message zurück (Session "completed", aber `(no content)`). Bekanntes opencode-MCP-Verhalten bei längeren strukturierten Prompts an Anthropic-Provider; nicht heute behebbar. Council reduziert sich auf 2 Stimmen (GPT-5 + Grok-4). Aussagen-Robustheit deshalb geringer — überall wo nur eine Stimme spricht, ist das markiert.

---

## 1. Neuer Stack (Kurzfassung)

- **cc-yolo (PS-Wrapper):** setzt `$env:CCSC_SESSION_NAME` vor `& claude`; Name Pflicht (arg oder `Read-Host`).
- **Bridge (Node/TS stdio-MCP):** liest ENV, direkter Postgres-Connect, registriert in `coord.sessions`, `LISTEN ccsc_inject_<id>` + `LISTEN ccsc_hook_<id>`. Bei NOTIFY: Row-Fetch, `notifications/claude/channel` an claude.exe, `delivered_at = now()`. Exposed MCP-Tools für `/coord *`.
- **Hooks (PS):** PreToolUse liest Postgres direkt (Conflict-Block via `exit 2`). PostToolUse/Stop schreiben `coord.activities` via `psql -c INSERT` o. Npgsql. Lifecycle-Hooks (SessionStart/UserPromptSubmit/SessionEnd) entfallen — Bridge übernimmt.
- **Worker:** `/health` + optional `/dashboard`. Push-Pfad, SSE, Channel-Registry, Watchdog, Token-Store komplett raus. Abschaltung als NSSM-Service möglich.
- **Multi-Maschine:** kostenlos durch Remote-Postgres-Connection.

---

## 2. Konsens pro Frage

### Frage 1 — Performance LISTEN/NOTIFY

**Konsens:** Unkritisch für die Ziel-Last. 10-50 dauerhafte Listener + einige hundert NOTIFY/Tag sind für Postgres "trivial" (GPT-5) bzw. "absolut realistisch" (Grok-4). Postgres schafft im Normalfall tausende NOTIFY/s. Lokal-LAN-Roundtrip < 5-20 ms.

**Konfig-Knöpfe (Konsens beider):**
- `max_connections`: realistisch 100-200 (default 100 reicht meist) — Bridges + Admin + Apps + Wartungs-Puffer.
- `tcp_keepalives_*` hochdrehen (GPT-5) — NAT/Firewall-Idle-Drops auf langlebigen Listener-Connections vermeiden.
- `shared_buffers` 25 % RAM (Grok-4) — Standard-Tuning.

**Disagreement:**
- **PgBouncer:** GPT-5 warnt explizit: nur **Session-Pooling**, **Transaction-Pooling bricht LISTEN/NOTIFY**. Grok-4 erwähnt es nicht. → **GPT-5 gewinnt** (faktisch korrekt: `LISTEN`-State ist session-gebunden).
- Grok-4 nennt `listen_addresses = '*'` für Remote — Standardwissen, kein Konflikt.

> GPT-5: "pgbouncer nur im Session-Pooling (Transaction-Pooling bricht LISTEN/NOTIFY)"
> Grok-4: "Setze `max_connections` auf 100-200 (default 100 reicht oft)"

### Frage 2 — Caveats

**Konsens (überschneidend):** Disconnect-Verlust → Reconnect+SELECT-pending, 8-kB-Payload → id-only, Replication-Verhalten, Trigger-Cost ok.

**Zusatz-Caveats die wir noch NICHT auf der Liste hatten:**
- **`SKIP LOCKED` für Idempotenz (GPT-5):** Zustellung mit `SELECT … FOR UPDATE SKIP LOCKED` + `UPDATE delivered_at=now()` atomar — Mehrfach-NOTIFYs werden harmlos. **Wichtig** wenn mehrere Bridges versehentlich denselben Channel hören (z. B. nach Crash-Reconnect-Race).
- **Channel-Name-Länge ≤ 63 Bytes (GPT-5):** Session-IDs müssen kurz und sanitized sein — `ccsc_inject_<long-uuid>` knackt schnell das NAMEDATALEN-Limit.
- **NOTIFY-Coalescing im selben TX (GPT-5):** Mehrere NOTIFY pro TX werden pro Listener/Channel zusammengefasst → man darf nicht annehmen "jeder Event wird einzeln zugestellt". Konsequenz: Row-IDs müssen lückenlos selektierbar sein, nicht von NOTIFY-Zählung abhängig.
- **NOTIFY repliziert nicht über Streaming-Replication (beide):** Listener müssen am Primary hängen.
- **Async-Notification-Queue ist bounded (Grok-4):** Bei Stau kann sie überlaufen. Bei unserer Last unrealistisch, aber bei Burst (z. B. 100 Hook-Events/s) zu beachten.
- **Security/Roles (Grok-4):** Bridge-User mit minimalen Rechten (NOTIFY, SELECT auf `coord.*`, gezielte UPDATEs). Kein Superuser.
- **Backpressure (beide):** Bei hohem Rückstand drosseln/batchen.

### Frage 3 — MCP-Capability

**Konsens:** Beide kennen **keine** öffentlich dokumentierten weiteren experimentellen MCP-Capabilities außer `claude/channel`. Beide sind explizit ehrlich: "weiß ich nicht".

**Quellen-Empfehlung (GPT-5):** Anthropic MCP-Spec auf GitHub und Desktop-Release-Notes. **"keine konsolidierte Referenz für experimentelle Flags gesehen"**.

**Praxis-Empfehlung (GPT-5):** Capabilities **feature-detecten** im Client-Handshake, hartes Failover auf Polling/Status-Tool wenn `claude/channel` fehlt. CI-Check der Handshake-Antwort surfacing Änderungen.

> GPT-5: "experimental/* ist Client-spezifisch und ändert sich ohne SemVer"

### Frage 4 — MCP-Proxy-Vision

**Konsens:** Architektur entspricht klassischem **Job-Queue + Worker-Pool**-Pattern (NOTIFY trägt Request-ID, Worker konsumiert, Response-Row, Bridge LISTEN auf Response-Channel). Latenz auf LAN typ. **5-100 ms** (Grok-4: 10-100 ms, GPT-5: 5-20 ms) — vernachlässigbar gegen Tool-Latenz selbst.

**Bestehende Lösungen:** Beide kennen **kein etabliertes "proxy-mcp" / "mcp-router"** als produktionstaugliches Off-the-Shelf-Produkt. Generische Patterns existieren (Debezium, PgQ, NATS, Redis-Streams), aber MCP-spezifisch ist es ein DIY-Projekt.

**Bruchstellen (Konsens):**
- **Context-Isolation per Session:** ACL bzw. Row-Level Security nötig — Session A darf nicht Session Bs MCP-Responses sehen.
- **Backpressure / Head-of-Line:** lange Tool-Calls blocken Worker-Slots. Priorisierung erforderlich.
- **Große Responses:** DB-Row/TOAST-Bloat — große MCP-Antworten (z. B. Hindsight-Suche mit 50 Treffern) belasten WAL.
- **Error-Handling/Dead-Letter:** fehlende ACKs → Lost Messages. Retry-Policy + DLQ-Tabelle nötig.

**Migrationspfad bei Wachstum (GPT-5):** Pattern bleibt; bei höherer QPS auf NATS/Redis-Streams umstellbar.

### Frage 5 — Migration / Grüne Wiese

**Konsens-Liste was wir verlieren könnten:**
- **Audit/Activity-History (beide):** GPT-5 empfiehlt **min. 7-30 Tage** Activity-Log zumindest forensisch zu erhalten. Grok-4 erwähnt es nur generisch. **Konkrete Frage:** brauchen wir die historischen `coord.activities` für irgendwas (Konflikt-Pattern-Analyse, Bug-Repro)?
- **`last_seen_id` pro Session (GPT-5):** Sobald die neue Welt läuft, ist es der wichtigste Bridge-State für Reconnect-Wiederaufnahme. Bei kompletter Auslöschung der alten DB egal — aber bei künftigen Schema-Bumps mitnehmen.
- **Konflikt-Detektions-Entscheidungen:** wenn jemals eine Frage kommt "warum hat das System damals File X geblockt?" — heute ohne History weg.

**Sauberer-Aufbau-Schritte (GPT-5, detaillierter als Grok-4):**
1. Neues Schema + Indizes + Funktionen (idempotente enqueue/dequeue als SQL-Functions).
2. Bridge: LISTEN/SELECT-Pfad bauen; Hooks nur Writes (Activities, Stop).
3. **Schattenbetrieb:** alte Welt aktiv, neue Bridge passiv mitliest/verprobt **(eigentlich nicht möglich, weil DB gedroppt wird — aber empfohlene Praxis)**.
4. Canary 5-10 % Sessions.
5. Umschalten, Worker deaktivieren, alte Tabellen als Dump archivieren.
6. Cleanup: SSE/HTTP-Pfade raus, Dashboards auf SQL-Views.

**Grok-4 Schritte (knapper, klassischer):** Backup → Stop → Drop Schema → Create → Start → Test.

**Disagreement:** GPT-5 möchte **Schattenbetrieb**, Grok-4 macht **harten Cut**. Vor dem Hintergrund "grüne Wiese laut User" passt Grok-4 besser zum User-Wunsch. Empfehlung: **harter Cut, aber DB-Dump als ZIP archivieren** — kostet nichts und gibt Forensik-Option.

---

## 3. Empfehlungs-Liste (Priorität ↓)

1. **SKIP LOCKED + atomarer Status-Update** im Delivery-Pfad — verhindert Doppel-Zustellung bei Reconnect-Races. (P0)
2. **PgBouncer-Modus dokumentieren:** falls eingesetzt, **Session-Pooling** zwingend (Transaction-Pooling bricht LISTEN). (P0)
3. **Channel-Namen ≤ 63 Bytes:** Schema-Konvention festlegen — z. B. `c_i_<short-id>` und `c_h_<short-id>` statt `ccsc_inject_<uuid>`. (P0)
4. **NOTIFY-Coalescing einplanen:** Bridge muss bei jedem Wakeup `SELECT … WHERE delivered_at IS NULL ORDER BY id` machen, nicht pro NOTIFY genau eine Row erwarten. (P0)
5. **Capability-Feature-Detection:** Bridge prüft beim Handshake `claude/channel`, fällt auf Polling-Loop-Tool zurück wenn fehlt. CI-Test der Handshake-Antwort. (P1)
6. **Bridge-User minimal-privilegiert:** dedizierte PG-Rolle `ccsc_bridge` mit nur `NOTIFY`, `SELECT` und gezielten `UPDATE`-Rechten. (P1)
7. **DB-Dump der alten Welt vor Drop als Archiv** (`ccsc_legacy_2026-05-14.sql.gz`) — billiger Forensik-Backup. (P1)
8. **Async-Notification-Queue-Größe** überwachen (`pg_notification_queue_usage()`) — frühes Burst-Warnsignal. (P2)
9. **TCP-Keepalives** auf langlebige Listener-Connections hochdrehen — verhindert stille NAT-Drops. (P2)
10. **MCP-Proxy-Vision in Phase 2:** zunächst nur die LISTEN/NOTIFY-Bridge bauen, Proxy-Daemon erst später; vorher RLS + DLQ + Priorisierung spezifizieren. (P2)

---

## 4. Open Questions (für echte Tech-Spec)

- **Channel-Name-Schema:** kurze IDs, aber wie sicherstellen dass `short_id` global unique über Multi-Maschine ist? UUIDv7-Prefix? Hash über `machine + pid + start`?
- **PreToolUse-Latenz-Budget:** Hook blockiert claude.exe synchron. Wie schnell muss der Postgres-Roundtrip sein? Bei Remote-DB potentiell 50-200 ms — akzeptabel? Cache-Layer?
- **Multi-Maschine + Time-Skew:** `delivered_at = now()` ist DB-Zeit (gut), aber Activities mit Hook-Timestamps (Maschinen-Zeit) müssen mit `now() AT TIME ZONE 'UTC'` normalisiert werden.
- **Worker komplett weg oder bleiben?** Dashboard kann als statisches HTML mit pg-direkt-Query laufen — aber `/health` für NSSM-Restart-Logic ist sinnvoll, falls die DB selbst über Bridge-Heartbeat überwacht werden soll.
- **DLQ-Strategie:** was passiert mit Injections die 3x ge-retry'd wurden und immer noch `delivered_at IS NULL`? Auto-Expire nach 24h? Warnung via Dashboard?
- **Bridge-Crash-Erkennung:** Postgres `pg_stat_activity` zeigt Connection-Drop. Wer setzt `coord.sessions.status = 'ended'`? Trigger auf Connection-Close gibt es nicht — entweder Watchdog-Query oder ein leichter Heartbeat-NOTIFY alle 30s.
- **MCP-Proxy-Vision: Authn?** Welche Session darf welchen MCP-Endpoint ansprechen? hindsight/socraticode/gitnexus brauchen evtl. unterschiedliche Berechtigungen.
- **Capability-Negotiation-Persistenz:** Wenn `claude/channel` mal weg ist (neuere claude.exe-Version) — warnt das System? Loggt es? Stoppt es Injects?
- **PostgreSQL-Version-Floor:** `SKIP LOCKED` ab PG 9.5, `LISTEN/NOTIFY` immer da — welche Minimum-Version spezifizieren wir?
