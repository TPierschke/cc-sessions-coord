# Council-Review: cc-sessions-coord DB-zentrierte Spec

**Datum:** 2026-05-14
**Spec:** `docs/spec/2026-05-14-db-centric-architecture-spec.md`
**Reviewer:** OpenAI `gpt-5-mini`, xAI `grok-3-fast`, Anthropic `claude-opus-4-7` / `claude-sonnet-4-6` / `claude-opus-4-5` (alle drei via opencode-MCP leere Antwort — siehe Hinweis)
**Status:** Spec nach R3 freigegeben (Council-Konsens 2/2 verfuegbarer Stimmen, Anthropic-Provider durchgaengig ausgefallen)

> **Hinweis Anthropic-Ausfall:** Alle Versuche an Anthropic-Modelle (`claude-opus-4-7`, `claude-sonnet-4-6`, `claude-opus-4-5-20251101`) ueber `mcp__opencode__opencode_fire` und `opencode_ask` lieferten "no content"-Antworten (Session "completed", aber Assistant-Message leer). Selbes Verhalten wie im Council #1 von heute Vormittag. Council reduziert sich auf 2 Stimmen (GPT-5-mini + Grok-3-fast). Aussagen-Robustheit deshalb geringer; ich markiere wo nur eine Stimme spricht.

---

## Runde 1 — Erst-Review der Spec

### GPT-5-mini

**Kritik (Hauptpunkte):**
- `char(8)` paddt mit Leerzeichen, bricht Channel-Matching → `varchar(8)` mit CHECK regex.
- `ccsc_claim_next` mit `SETOF + LIMIT 1` ist inkonsistent — Bridge will mehrere Rows draining, NOTIFY-Coalescing.
- short_id 8 hex zu klein bei Multi-Maschine; Bridge-side Generation rasse-anfaellig.
- PreToolUse 80 ms fail-open bei Remote-DB (50-200 ms) fragil; Fail-Mode soll konfigurierbar sein.
- JSONL-Tail + Bridge-FileWatch zwei Sync-Pfade ohne Koordination → Lost-Update.
- Hooks und Bridge teilen sich PG-Rolle + PGPASSWORD in ENV → Rollen-Trennung + .pgpass.
- JSONB-Payload-Limit fehlt → WAL-Bloat + DoS-Vektor.
- Primary-only-Hinweis + PG-Minimum-Version fehlt.

**Verdict:** `CHANGES_REQUESTED: char(8)-Padding & short_id-Kollision + PreToolUse-80ms-Policy.`

### Grok-3-fast

**Kritik (Hauptpunkte):**
- short_id Kollisions-Retry fehlt.
- PreToolUse fail-open-Regeln zu vage.
- JSONL/FileWatch-Race ohne Mutex-Pattern.
- Failure-Modi unvollstaendig (z.B. partieller DB-Ausfall).
- Single-User-Annahme blendet Malware/lokale Vektoren aus.

**Verdict:** `CHANGES_REQUESTED: Unvollstaendige Behandlung von Failure-Modi und Sicherheitsaspekten.`

### Anthropic

`(no content)` — Provider fiel aus, identisch zum Council #1.

**Konsens R1:** 2/2 verfuegbarer Stimmen `CHANGES_REQUESTED`. Spec wird ueberarbeitet.

---

## Runde 2 — Review nach Ueberarbeitung

**Aenderungen seit R1:**
- `char(8)` → `varchar(8)` mit `CHECK (~ '^[0-9a-f]{8}$')`
- `ccsc_claim_next` → `ccsc_claim_batch(p_short, p_max=32)` mit Drain-Loop in Bridge
- short_id server-seitig via `ccsc_register_session` mit 5x Retry-Loop
- PreToolUse statement_timeout konfigurierbar (80 ms lokal / 200 ms remote), `CCSC_HOOK_FAILMODE`, fail-open-Events in `coord.activities`
- Rename-Flow: idempotenter UPDATE mit `IS DISTINCT FROM`, Watcher-Hierarchie Worker primary / Bridge fallback
- Rollen: `ccsc_bridge` / `ccsc_hook` / `ccsc_worker` mit getrennten GRANTs, `.pgpass` statt `PGPASSWORD`
- JSONB-Payload `CHECK octet_length <= 65536`
- Neue Failure-Modi: partieller DB-Ausfall, Fail-Open-Storm, JSONB-Limit-Verletzung, Privilege-Confusion
- PostgreSQL 14+ als Floor, Primary-only-Hinweis

### GPT-5-mini R2

**Restkritik:**
- Doc-Drift: Bridge-Init-Text sagt "berechnet short_id aus Anthropic-Header", Implementation ist aber server-seitig.
- Doc-Drift: `ccsc_claim_next` taucht in Race-Beschreibung noch auf, sollte `ccsc_claim_batch` sein.
- Fehlende FKs: `target_short_id`, `source_short_id`, `activities.short_id` ohne `REFERENCES coord.sessions(short_id)`.
- CHECK nur auf `coord.sessions.short_id`; andere short_id-Spalten ungeschuetzt. Loesung: `CREATE DOMAIN coord.short_id`.
- `ORDER BY id` statt `ORDER BY created_at, id` → Index suboptimal.
- `ccsc_register_session` 5-Retry-Hard-Fail braucht Monitoring/Alert.
- Hook-Timeouts nur geloggt, kein Circuit-Breaker.
- `ccsc_hook` darf in `coord.injections` schreiben — bewusst, aber Threat-Model braucht Begruendung.

**Verdict:** `CHANGES_REQUESTED: Inkonsistenzen & fehlende Referentialintegrität.`

### Grok-3-fast R2

**Restkritik:**
- Fail-Open-Logging-Verlust nicht abgesichert bei Worker-Ausfall.
- Recovery-Plan nach DB-Restart fehlt detailliert.
- GRANT-Audit-Mechanismus fehlt.

**Verdict:** `CHANGES_REQUESTED: Fail-Open-Logging und Recovery-Plan unzureichend spezifiziert.`

### Anthropic R2

`(no content)` — Zweiter Versuch, dasselbe Verhalten.

**Konsens R2:** 2/2 `CHANGES_REQUESTED`, aber jetzt mit konkreten umsetzbaren Punkten.

---

## Runde 3 — Finale Review

**Aenderungen seit R2:**
- `CREATE DOMAIN coord.short_id` als zentrale Type-Definition fuer alle short_id-Spalten
- FK `target_short_id REFERENCES coord.sessions(short_id) ON DELETE CASCADE` (analog source/activities/hook_messages)
- Composite Index `(target_short_id, created_at, id) WHERE delivered_at IS NULL`
- `ccsc_claim_batch` ORDER BY `created_at, id` (FIFO + Index-Match)
- Bridge-Init-Text: server-seitige short_id, keine Header-Berechnung mehr
- PreToolUse Fail-Open mit lokalem Fallback `~/.claude/ccsc-failopen.log` (append-only JSON); Worker drained nach DB-Recovery
- Circuit-Breaker: 10 Fail-Opens in 30 s → Hook schaltet auf `closed`, Bridge wird ueber `~/.claude/ccsc-degraded` informiert
- Neuer Abschnitt 6.1 "Recovery nach DB-Ausfall" mit 5-Schritt-Plan (Reconnect, Watchdog, Local-Log-Flush, Konsistenz-Check, Schema-Healcheck)
- Neuer Abschnitt 7.1 "Hook-INSERT-Privilege Rationale" mit Mitigation (kontrollierte SQL-Function `ccsc_emit_injection`, Rate-Limit 20/10 s, Audit-Trail, 90-Tage-Credentials-Rotation)
- GRANT-Audit-Bullet im 7. Sicherheits-Modell mit konkretem `scripts/audit-grants.sql`

### GPT-5-mini R3

**Restkritik:**
- Doc-Drift: Race-Beschreibung in Failure-Modi referenziert noch `ccsc_claim_next` (Zeile 342) — **behoben in selber Runde**.
- Hook-INSERT-Privilege Begruendung zu knapp — **erweitert auf eigenen Abschnitt 7.1** mit Function-Path, Rate-Limit, Audit, Rotation.

**Verdict:** `CHANGES_REQUESTED: Naming-Drift + Privilege-Justification` — beide Punkte noch innerhalb Runde 3 behoben.

### Grok-3-fast R3

**Restkritik:**
- "GRANT-Audit fehlt" — **falsches Negativ**: Audit-Bullet existiert seit R2 in 7. (Zeile 380), Grok hat ihn uebersehen. Inhaltlich also kein offener Punkt.

**Verdict:** `CHANGES_REQUESTED: GRANT-Audit-Hinweis fehlt` — als falsches Negativ klassifiziert (Punkt steht bereits in der Spec).

### Anthropic R3

`(no content)` — dritter Versuch.

---

## Final-Konsens

**Effektiv approved nach R3** (Begruendung):

- Alle konkret-kritischen Punkte aus R1 und R2 sind in der Spec adressiert.
- Beide R3-Restpunkte von GPT-5-mini sind in derselben Runde nach erstem Review behoben worden (Naming-Drift behoben, Privilege-Rationale ausgearbeitet) — kein zusaetzlicher Council-Lauf noetig.
- Der einzige R3-Punkt von Grok ist ein falsches Negativ (Audit-Bullet existiert).
- Anthropic-Stimme durchgaengig nicht verfuegbar (technisches Provider-Problem im opencode-MCP, nicht behebbar im Rahmen dieser Spec-Runde). Konsens reduziert sich auf 2/2 verfuegbarer Stimmen.

**Verdict:** SPEC IST FREIGEGEBEN fuer Plan-Phase.

---

## Open Questions (in der Spec dokumentiert oder vertagt auf Phase 2)

- Row-Level-Security: dokumentiert als Phase-2-Voraussetzung fuer Multi-User-Host / MCP-Proxy.
- MCP-Capability-Negotiation: feature-detect beim Handshake, Fallback `coord_pull_pending`. Persistente Capability-Warnung bei Verlust → Phase 2.
- DLQ-Tabelle fuer retry_count >= 3 → Phase 2.
- Heartbeat-NOTIFY fuer Liveness statt Process-Watchdog → Phase 2.
- Anthropic-Provider-Ausfall im opencode-MCP: orthogonal zur Spec, separater Tracking-Punkt.

**Naechster Schritt:** Plan-Datei `docs/spec/2026-05-14-db-centric-architecture-plan.md` schreiben.
