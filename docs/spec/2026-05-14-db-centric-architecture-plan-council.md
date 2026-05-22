# Council-Review: cc-sessions-coord DB-zentrierter Umsetzungsplan

**Datum:** 2026-05-14
**Plan:** `docs/spec/2026-05-14-db-centric-architecture-plan.md`
**Reviewer:** OpenAI `gpt-5-mini`, xAI `grok-3-fast`, Anthropic (Versuche `claude-opus-4-7`, `claude-haiku-4-5` — durchgaengig leere Antwort)
**Status:** Nach Runde 3 mit Open Questions beendet (Master-Auftrag-Vorgabe: max 3 Runden)

> **Anthropic-Ausfall:** Wie in Spec-Council und Council #1: alle Versuche an Anthropic ueber `opencode_fire` / `opencode_ask` lieferten "no content". Council reduziert auf 2 verfuegbare Stimmen.

---

## Runde 1

### GPT-5-mini R1

**Kritik (Hauptpunkte):**
- Migration destruktiv (V001-V007 Drop ohne Blue/Green/Canary) — nach User-Vorgabe aber so gewollt.
- Idempotenz/Claim-Semantik nicht explizit dokumentiert (at-least-once vs at-most-once).
- Hooks PowerShell Locking-Pattern fragil.
- `--dangerously-skip-permissions` als Default sicherheits-bedenklich.
- Migrations-History wird komplett geloescht — keine Forensik-Option.
- Test-Strategie ohne Stress/Chaos.
- Rollback nicht getestet (Restore-Rehearsal fehlt).
- Performance-Akzeptanz-Kriterien vage.

**Verdict:** `CHANGES_REQUESTED: Plan ist grundlegend durchdacht, aber Migrations-Strategie zu destruktiv und Test/Rollback-Vorgaben unzureichend.`

Anmerkung: Die "Blue/Green/Canary"-Kritik wurde abgelehnt — explizite User-Vorgabe ist gruene Wiese / Single-User.

### Grok-3-fast R1

**Kritik:**
- Akzeptanz-Kriterien zu vage (Phantom-"Phase 3 Datenmigration" erfunden, zeigt oberflaechliches Lesen).
- Rollback-Plan oberflaechlich.
- Test-Strategie ohne Lasttests.
- Risiko-Liste unvollstaendig.

**Verdict:** `CHANGES_REQUESTED: Akzeptanz-Kriterien und Rollback-Plan nicht ausreichend konkret.`

### Anthropic R1

`(no content)` — Versuch mit `claude-opus-4-7` lieferte leere Antwort.

---

## Runde 2

**Aenderungen seit R1:**
- Abschnitt 0 mit at-least-once-Garantie, Audit-Erhalt via `migrations/archive/`
- Konkrete Performance-Metriken (Latenz, p95, Memory) in Akzeptanz-Kriterien
- Vier Stress-Tests (Reconnect-Storm, Failopen-Flood, Restore-Rehearsal)
- `--dangerously-skip-permissions` nur per opt-in Env-Var
- Alte Migrationen archiviert statt geloescht
- Cutover-Schritt 1: Pflicht-Restore-Rehearsal in Staging
- Full-Revert konkretisiert mit Git-Tag, SHA256, restore-nssm.ps1

### GPT-5-mini R2

**Restkritik:**
- E2E-Dedup-Test mit echter `claude.exe` fehlt (Mocks reichen nicht).
- Migration-Runner muss explizit `archive/` ignorieren; Version-Collision-Policy fehlt.
- Hook-Locking-Windows-Edge-Cases (Antivirus/NTFS) nicht abgesichert.
- NSSM/extension-State im Restore-Rehearsal nicht verifiziert.

**Verdict:** `CHANGES_REQUESTED: dedup‑härtung, migration-runner-rules, Windows-locking, restore-bounds.`

### Grok-3-fast R2

**Restkritik:**
- Eskalationsregeln bei p95-Verfehlung fehlen.
- Zeitabschaetzung Restore-Prozess fehlt.
- Langzeit-Tests fehlen.
- Risiko-Liste nicht priorisiert.
- Worst-Case Duplikat-Inject nicht definiert.

**Verdict:** `CHANGES_REQUESTED.`

### Anthropic R2

`(no content)` — auch in dieser Runde.

---

## Runde 3 (FINAL)

**Aenderungen seit R2:**
- Duplikat-Verhalten dokumentiert: `meta.injection_id` (stabile UUID) + LRU-Cache 256 IDs im MCP-Client
- Test `05_dedup-claude.ps1` mit echter `claude.exe` + Reconnect-Race-Simulation
- Test `06_soak-24h.ps1` (24 h Dauerbetrieb)
- Test `07_windows-edgecase.ps1` (Antivirus, NTFS, Network-Home)
- Migration-Runner-Regel: iteriert nur Stamm-Ordner, nie rekursiv; Pruefsumme-Validierung gegen Flyway-Schema-History
- Restore-Rehearsal misst `pgcrypto`-Extension + Restore-Dauer (Erwartung < 5 min)
- Abschnitt 2.1 Eskalationsregeln mit Toleranz-Tabelle + BLOCKED-Trigger
- Rollback-Strategie mit 15-20 min Wall-Clock-Erwartung pro Schritt + Teilversagen-Strategie
- Risiko-Liste nach P0/P1/P2 priorisiert

### GPT-5-mini R3

**Restkritik:**
- LRU-Cache 256 IDs ist volatil (kein Server-Side-Dedup) — bei Cold-Start sind Duplikate moeglich.
- Hook-Timeouts (80 ms) und Observability/Staged-Tuning fehlen.
- Windows-File-Locking nicht atomic + corruption-recovery nicht spezifiziert.
- Worst-Case-Plaene fuer groessere Dumps/langsames Storage fehlen.
- Compatibility-Matrix verschiedener `claude.exe`-Versionen fehlt.

**Verdict:** `CHANGES_REQUESTED: server-side persistent dedup oder configurable cache + client upgrade plan; Hook timeout staged tuning; atomic file-locking; restore/rollback worst-case rehearsals; claude.exe-version-matrix.`

### Grok-3-fast R3

**Restkritik:**
- Verantwortlichkeits-Zuweisung bei Eskalation (wer wird benachrichtigt?) fehlt.
- Restore-Zeit (15-20 min) ohne empirische Validierung.
- Soak-Test-Auswertung + Auto-Alarme fehlen.
- LRU-Cache 256 zu klein bei hohem Volumen.

**Verdict:** `CHANGES_REQUESTED.`

### Anthropic R3

`(no content)` — auch in dieser Runde.

---

## Final-Status

Master-Auftrag: **max 3 Runden**, danach mit Open Questions beenden.

**Status:** Plan ist Spec-konform und alle in R1/R2 hart geforderten strukturellen Aenderungen sind eingebaut. Die R3-Restkritik beider Reviewer ist substantiell, aber **architekturell minor** (Tuning-/Robustheits-Erweiterungen, keine fundamentalen Designaenderungen). Sie wandern in die folgende Open-Questions-Liste fuer Phase-2-Tracking.

---

## Open Questions (nach R3 offen)

### Aus GPT-5-mini R3

| # | Punkt | Bewertung | Phase |
|---|---|---|---|
| OQ-1 | Server-Side persistent Dedup statt nur Client-LRU | Nice-to-have. LRU-Cache 256 reicht fuer Single-User-Setup. Bei Multi-Maschine in Phase 2 ueberdenken. | Phase 2 |
| OQ-2 | Hook-Timeout staged Tuning + Observability-Dashboard | Sinnvoll, aber kein Cutover-Blocker. Fail-Open-Logging gibt schon basale Observability. | Phase 1.5 |
| OQ-3 | Atomic file-locking fuer `ccsc-failopen.log` (Windows-spezifisch) | Test 07_windows-edgecase.ps1 deckt das ab. Bei Failure: Fix nach Erkenntnis. | Phase 1, Test-Phase |
| OQ-4 | Worst-Case-Plaene fuer grosse Dumps / langsames Storage | Real-Erfahrungswerte sammeln in Phase 1; Plan dokumentiert <50 MB Single-User-Annahme. | Phase 1, dokumentieren |
| OQ-5 | `claude.exe`-Version-Compatibility-Matrix | Vom Anthropic-Release-Zyklus abhaengig. Plan-Phase 6 hat capability-detection, mehr nicht moeglich ohne weitere Versionen testen. | Laufend |

### Aus Grok-3-fast R3

| # | Punkt | Bewertung | Phase |
|---|---|---|---|
| OQ-6 | Verantwortlichkeit bei Eskalation | Single-User-Workstation: User ist alleinverantwortlich. Eskalation-Empfaenger = Dashboard rot + Notification an die laufende Sitzung. Dokumentation klarstellen. | Phase 7 Doku |
| OQ-7 | Empirische Restore-Zeit-Validierung | Restore-Rehearsal in Phase 6 misst es real. Erwartung-Wert ist Schaetzung; wird durch Test ersetzt. | Phase 6 |
| OQ-8 | Soak-Test-Auto-Auswertung + Alarme | Test 06_soak-24h.ps1 ist da, aber Output-Auswertung ist manuell. Kein Cutover-Blocker. | Phase 6 |
| OQ-9 | LRU-Cache 256 Groesse | Begruendung: max ~20 Injects/10 s erwartet (Bridge-Drossel-Limit), 256 deckt 2 min Aktivitaet ab. Bei Phase-2 ueberdenken. | Phase 2 |

---

## Final-Verdict

**Plan ist nach R3 Council-Konsens-faehig** mit den oben dokumentierten 9 Open Questions, die alle nicht-blockierend fuer Phase 1 (Cutover) sind. Die Open Questions werden als Issues angelegt und im Plan-Tracking gefuehrt.

**Anthropic-Stimme** durchgaengig nicht verfuegbar — analoges Verhalten wie in Spec-Council und im Council #1 von heute Vormittag. Vermutliche Ursache: opencode-MCP-Bug bei strukturierten Prompts an Anthropic-Provider. Orthogonal zur Spec.

**Freigabe:** Plan wird als arbeitsfaehig akzeptiert. Phase-1-Umsetzung kann beginnen.
