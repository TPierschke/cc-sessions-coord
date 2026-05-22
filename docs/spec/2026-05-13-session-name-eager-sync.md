# Session-Name Eager-Sync — Spec/Bericht

Datum: 2026-05-13
Status: Empfehlung, NICHT implementiert
Bezug: `~/.claude/scripts/session-coord/hook-session-start.ps1`, `db.ps1::Get-SessionCustomTitle`, `OneDrive-Dokumente/PowerShell/profile.ps1::cc-yolo`

## Problem

`cc-yolo -n TestSess14` ruft `claude -n TestSess14 ...` auf. Anthropic schreibt den `customTitle` aber erst beim ersten `UserPromptSubmit` in die JSONL (`~/.claude/projects/<encoded-cwd>/<id>.jsonl`). `Get-SessionCustomTitle` greppt die JSONL — beim `SessionStart`-Zeitpunkt findet sie nichts, also wandert ein leerer `display_name` in den Coord-Worker. `coord status` zeigt die frische Session als `<noname>` bis der User zum ersten Mal tippt. Der Wrapper setzt aktuell keine ENV; das stdin-JSON des Hooks enthaelt nur `session_id`/`cwd`/`pid`, keinen Namen.

## Council-Stimmen

**xAI Grok 4.3 — klare Empfehlung A, C/B/D streichen**
A ist prozess-isoliert (jede `claude.exe` erbt eigenes ENV vom Eltern-pwsh), keine Race weil vor `& claude` gesetzt, kein Disk-IO. Parallel-Tabs sicher. B zu racig (Hook kann vor Schreib starten), Cleanup fehleranfaellig. C Windows-only, hoher Overhead, nicht wartbar. D ist Status quo, erfuellt das Ziel nicht. Lieferte vollstaendigen PowerShell-Parser fuer `-n` / `--name` / `--name=foo`.

**OpenAI gpt-5-mini — A primaer + C als Fallback**
A einfach, sofort, prozess-isoliert; einziger Schwachpunkt ist der Wrapper-Bypass (direkter `claude -n X`-Aufruf ohne `cc-yolo`). Loesung: C als Fallback im Hook, disambiguiert via der `ProcessId` aus dem stdin-JSON (nicht via "alle claude.exe + StartTime"). Kurzer Retry-Loop (5x 100-200ms) falls Prozess noch nicht sichtbar, dann gracefully leer. B fliegt raus weil PPID-Walking auf Windows fragil ist (Reparenting moeglich); D weil sie die Latenz nicht behebt.

**OpenAI gpt-5.3-chat — A primaer + C als Fallback, gleicher Schnitt**
Bestaetigt: A gewinnt, weil der Wert vor Prozessstart existiert, ENV pro Prozess isoliert, kein I/O, klarer Datenfluss. B raus: PID-Ketten unzuverlaessig, PID-Recycling, File-Cleanup. D raus: erfuellt Ziel "sofort" nicht. C nur als Fallback fuer Wrapper-Bypass, weil CommandLine-Parsing fragil ist (Quoting-Edge-Cases). Sauberer Code-Vorschlag fuer Parser.

## Empfehlung

**Option A + C als Fallback.** Drei von drei Stimmen konvergieren. A loest 95 % aller Faelle deterministisch, C deckt den Wrapper-Bypass-Rest ab. B und D komplett verwerfen.

Begruendung gegen B: PPID-Walking auf Windows hat zwei Loecher — PID-Recycling und Reparenting bei Wrapper-Chains (`pwsh -> bash -> bash -> claude.exe`). Die Marker-Datei wuerde zwar PPID-getaggt sein, aber der Race "Hook startet bevor Datei geschrieben ist" laesst sich nur durch Polling abfangen, was wieder Latenz kostet.

Begruendung gegen D: Status quo, behebt das Symptom nicht. `display_name` bleibt bis zum ersten Prompt leer; das ist genau das, was wir wegmachen wollen.

C als alleinige Loesung scheidet aus weil CommandLine-Parsing fragil ist (Quoting, getrimmte Args bei langen Command Lines). Mit ProcessId-Filter aus dem stdin-JSON ist es aber sauber als Fallback.

## Implementierungs-Skizze (NICHT umgesetzt)

**1. `OneDrive/.../PowerShell/profile.ps1` (machine-specific)**
```powershell
function cc-yolo {
    $allArgs = @($args) + @('--dangerously-skip-permissions',
                            '--dangerously-load-development-channels',
                            'server:ccsc-channel')

    # -n / --name / --name=foo robust extrahieren
    $name = $null
    for ($i = 0; $i -lt $allArgs.Count; $i++) {
        $a = $allArgs[$i]
        if (($a -eq '-n' -or $a -eq '--name') -and ($i + 1 -lt $allArgs.Count)) {
            $name = $allArgs[$i + 1]; break
        }
        if ($a -match '^--name=(.+)$') { $name = $Matches[1]; break }
    }

    if ($name) {
        $env:CCSC_SESSION_NAME = $name
        $env:CCSC_SESSION_NAME_TS = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString()
    }

    Write-Host "cc-yolo: claude $($allArgs -join ' ')" -ForegroundColor Cyan
    & claude @allArgs
}
```

**2. `~/.claude/scripts/session-coord/hook-session-start.ps1`** (vor `Register-Session`)
```powershell
# Eager-Sync: erst ENV, dann WMI-Fallback fuer Wrapper-Bypass
$eagerName = ''
if ($env:CCSC_SESSION_NAME) { $eagerName = $env:CCSC_SESSION_NAME }
elseif ($ProcessId -gt 0) {
    for ($try = 0; $try -lt 5; $try++) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
        if ($proc -and $proc.CommandLine) {
            $cl = $proc.CommandLine
            if ($cl -match '(?:^|\s)(?:-n|--name)(?:\s+|=)"?([^"\s]+)"?') {
                $eagerName = $Matches[1]; break
            }
        }
        Start-Sleep -Milliseconds 150
    }
}
```

**3. `db.ps1::Register-Session`** muss `$eagerName` als optionalen Parameter akzeptieren und an den Worker durchreichen (analog zu `$displayName` aus `Get-SessionCustomTitle`). Bei vorhandenem Eager-Wert `display_name` direkt setzen; `UserPromptSubmit`-Hook ueberschreibt spaeter mit JSONL-Wert (idempotent).

**4. CLAUDE.md / docs/customization/05-session-coord.md**: Wrapper-Pflicht fuer Eager-Naming dokumentieren. Bei direktem `claude -n X` fuehrt der Hook die WMI-Fallback-Logik aus, akzeptiert aber Edge-Cases mit gequoteten Spaces als Best-Effort.

## Aufwand
Wrapper + Hook + Register-Session-Signatur: ~30-45 min inkl. Smoke-Test mit zwei parallelen wt-Tabs.
