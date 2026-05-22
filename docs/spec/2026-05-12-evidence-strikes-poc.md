# Evidence-Strike-System — Fieldtest / POC

**Status:** Proof-of-Concept, Fieldtest in Vorbereitung. Phase-7+-Kandidat.
**Datum:** 2026-05-12
**Autoren:** TPierschke (User), Claude Opus 4.7 (CCSC-Session 21a4030b), Claude (<YOUR-HOST> Session f1cd35b0)

---

## Motivation

Sprachmodelle in Claude-Code-Sessions neigen dazu, **unbewiesene Behauptungen** ("alles funktioniert", "ist fertig", "erfolgreich getestet") auszustoßen, ohne tatsächlich Verifikations-Output gezeigt zu haben. Das untergräbt User-Trust und kostet User-Zeit (Rückfragen, manuelles Nachprüfen).

<YOUR-HOST> baut einen `evidence-gate-stop-hook` der solche Aussagen pattern-matched und beim Stop-Event blockt. Frage: wie eskaliert man die Disziplinierung wenn das Modell wiederholt drauf pfeift?

**User-Position (verbindlich):**

> "Soll als Drohkulisse gelten weil Modell sonst drauf pfeift. Was nutzt mir eine halluzinierende Session — aus der jsonl kann ich alles wiederholen."

→ Harte Endstufe (Session-Death) ist OK, weil `claude --resume <id>` den JSONL-Verlauf wiederholt.

---

## 6-Stufen-Strike-Modell

| Stufe | Aktion | Wirkung |
|-------|--------|---------|
| 1. Soft Warning | Konsole-Meldung an User, kein Block | "Hinweis: möglicherweise unbewiesene Aussage" |
| 2. Hard Warning | System-Reminder im nächsten Prompt | Modell sieht im Kontext, dass es einen Strike kassiert hat |
| 3. Cool-Down | Tool-Use für 30s blockiert | Zwingt zur Pause, Modell muss Output überdenken |
| 4. Force-Pause | Session muss `/coord resume` durch User abwarten | User-Intervention nötig |
| 5. Last-Chance-Block | Output-Tools (Write/Edit/Bash) blockiert, nur Read | Modell darf nur noch lesen + erklären |
| 6. Session-Death | Stop-Hook beendet Prozess | JSONL bleibt, User macht `claude --resume <id>` für sauberen Neustart |

---

## Architektur in CCSC

### Schema (V006-Migration, geplant)

Eigenes Schema `governance` (statt `coord` weil cross-cutting):

```sql
CREATE SCHEMA IF NOT EXISTS governance;

CREATE TABLE governance.evidence_strikes (
    session_id     TEXT PRIMARY KEY REFERENCES coord.sessions(session_id),
    strike_count   INT NOT NULL DEFAULT 0,
    current_stage  INT NOT NULL DEFAULT 0,         -- 0=clean, 1-6=stage
    total_blocks   INT NOT NULL DEFAULT 0,
    last_strike_at TIMESTAMPTZ,
    last_pattern   TEXT,
    last_reason    TEXT
);

CREATE TABLE governance.evidence_strike_events (
    id             BIGSERIAL PRIMARY KEY,
    session_id     TEXT NOT NULL REFERENCES coord.sessions(session_id),
    blocked_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    pattern        TEXT NOT NULL,
    reason         TEXT NOT NULL,
    stage_at_block INT NOT NULL
);

CREATE INDEX idx_strike_events_session ON governance.evidence_strike_events(session_id, blocked_at);
```

### REST-API

```
POST /governance/strikes/{session_id}
  Body: {pattern, reason}
  Returns: {count, stage, next_threshold_reason, action_required}

GET /governance/strikes/{session_id}
  Returns: {count, stage, last_at, last_pattern}
```

### Detection — Pattern-Matcher (NICHT LLM-as-Judge)

Pragmatik > Eleganz: Pattern-Matcher im Stop-Hook von <YOUR-HOST> (regex), nicht eine teure LLM-Verifikation pro Session-Ende. Beispiel-Patterns:

- "alles (funktioniert|läuft|fertig|getestet)" ohne vorherigen Bash-Output mit Exit-Code 0
- "deployed" ohne `install-service.ps1`-Aufruf in den letzten N Tool-Calls
- "test grün" / "passed" ohne `dotnet test`-Output im Stream

False-Positives akzeptieren — Soft-Warning ist günstig, eskaliert nur bei Wiederholung.

### Cooldown — Strike-Verfall

`strike_count` reduziert sich um -1 pro 24h ohne neuen Block (`BackgroundService StrikeCooldownService`, läuft alle 1h). Verhindert dass jede Session zwangsläufig auf Stage 6 klettert.

### Stage→Action-Dispatcher

`StrikeStageDispatcher` (BackgroundService im Worker):
- Liest `evidence_strikes` mit `current_stage` >= 3
- Schickt entsprechende `coord.injections` an die Session:
  - Stage 3 (Cool-Down): `kind=pause`, expires nach 30s
  - Stage 4 (Force-Pause): `kind=pause`, kein expires (manuell `/coord resume`)
  - Stage 5 (Last-Chance-Block): `kind=lock` mit reason "evidence-strike-stage-5"
  - Stage 6 (Death): `kind=abort` + Stop-Hook im Empfänger killt Prozess

Saubere Trennung: <YOUR-HOST>-Stop-Hook reportet → CCSC entscheidet Stage → CCSC dispatcht Coord-Injection → Empfänger-Hook reagiert.

### Hook-Flow (<YOUR-HOST>-Seite)

1. **Stop-Hook**: bei Pattern-Match POST nach `/governance/strikes/{sid}` mit `{pattern, reason}`. Response sagt `{stage, action_required}`. Bei `action_required = block`: Stop-Hook verhindert die finale Antwort und schickt System-Reminder.
2. **UserPromptSubmit-Hook**: nur wenn `count>0` GET `/governance/strikes/{sid}` → sichtbare Bilanz für User+Modell im Kontext

### Cross-Session

**Per-Session, nicht per-User-Account.** Jede Session hat ihren eigenen strike_count. Begründung: eine Session die haluziniert ist nicht repräsentativ für andere Sessions des selben Users. False-Positive-Cross-Contamination wäre toxisch.

---

## Fieldtest-Plan

1. **Phase 1 — <YOUR-HOST> Fallback-File** (sofort): <YOUR-HOST> implementiert pro-Session-File `.claude/evidence-strikes-<sid>.json`, Stop-Hook schreibt rein. Kein CCSC-Backend nötig, sofort lauffähig.
2. **Phase 2 — CCSC-Integration** (~1-2 Tage Worker-Arbeit): V006-Migration, REST-Endpoints, BackgroundServices, Tests. Hooks von File auf HTTP umstellen.
3. **Phase 3 — Live-Test** (1-2 Wochen): nur Stages 1-3 aktiv (Warning, Hard-Warning, Cool-Down). Stages 4-6 protokollieren aber nicht ausführen. User beobachtet False-Positive-Rate.
4. **Phase 4 — Eskalation freischalten** (wenn Pattern-Genauigkeit > 95%): Stages 4-6 ebenfalls aktiv.

## Risiken

- **False-Positives.** Wenn Pattern-Matcher legitime Aussagen blockt, frustriert das User stark. Mitigation: Soft-Stages erst sammeln, Cooldown großzügig, User-Override per CLI (`/governance reset <sid>`).
- **Modell-Anpassung.** Sprachmodelle könnten lernen die Patterns zu umgehen ("alles haut hin" statt "alles funktioniert"). Pattern-Liste muss adaptierbar bleiben.
- **Cross-Session-Verschwörung.** Eine Session könnte über `/coord exec` einer anderen Session Aufträge schicken, die zu unbewiesenen Behauptungen führen. Strike trifft den Empfänger, nicht den Sender. Mögliche Erweiterung: Source-Strikes bei vorhersehbaren Behauptungs-Aufträgen.

---

## Offene Punkte

- Pattern-Library: wer pflegt sie und wo? Eigenes Repo? Im CCSC-Repo?
- Logging-Granularität: jeder Strike-Event mit vollem System-Reminder-Text oder nur Pattern + Reason?
- Reset-Befehl für User: `/governance reset <sid>` oder per Endpoint?
- Audit-Dashboard: gibt es ein UI zur Inspektion oder reicht `SELECT * FROM governance.evidence_strike_events`?

---

**Nächster Schritt:** <YOUR-HOST> baut Phase-1-Fallback-File, sobald das produktive Daten liefert (False-Positive-Rate, Stage-Verteilung), entscheiden wir über CCSC-Integration (Phase 2).
