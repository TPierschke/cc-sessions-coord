#Requires -Version 7.0
<#
  Diagnose: Postgres-Dienst OK, aber 127.0.0.1:5432 antwortet nicht.
  Admin empfohlen. Nur lesen/testen — startet nichts neu.

  <repo-root>\scripts\diagnose-pg-loopback.ps1
#>
$PgBin = 'C:\Program Files\PostgreSQL\18\bin'
$PgData = 'C:\Program Files\PostgreSQL\18\data'
$PgIsReady = Join-Path $PgBin 'pg_isready.exe'

Write-Host "`n=== Dienste ===" -ForegroundColor Cyan
Get-Service postgresql-x64-18, 'DT - cc-sessions-coord' -ErrorAction SilentlyContinue | Format-Table Name, Status

Write-Host "`n=== postmaster.pid ===" -ForegroundColor Cyan
Get-Content (Join-Path $PgData 'postmaster.pid') -ErrorAction SilentlyContinue

Write-Host "`n=== pg_isready (verschiedene Hosts) ===" -ForegroundColor Cyan
foreach ($h in @('127.0.0.1', 'localhost', $env:COMPUTERNAME, '0.0.0.0')) {
    $o = & $PgIsReady -h $h -p 5432 2>&1 | Out-String
    Write-Host "  $h : $($o.Trim())"
}

Write-Host "`n=== netstat :5432 (nicht ESTABLISHED) ===" -ForegroundColor Cyan
netstat -ano | findstr ":5432" | findstr /V "ESTABLISHED" | Select-Object -First 10

Write-Host "`n=== pg_controldata (Cluster) ===" -ForegroundColor Cyan
& (Join-Path $PgBin 'pg_controldata.exe') $PgData 2>&1 | Select-String 'Cluster-Status|zuletzt'

Write-Host "`n=== Windows Event Log (PostgreSQL, letzte 3) ===" -ForegroundColor Cyan
Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'PostgreSQL' } -MaxEvents 3 -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host $_.Message }

Write-Host "`n=== Letzte PG-Logdatei (Tail 5) ===" -ForegroundColor Cyan
$log = Get-ChildItem (Join-Path $PgData 'log') -Filter 'postgresql-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($log) { Get-Content $log.FullName -Tail 5 }

Write-Host "`n=== Health ccsc ===" -ForegroundColor Cyan
try {
    Invoke-RestMethod 'http://127.0.0.1:7733/health' -TimeoutSec 4 | ConvertTo-Json -Compress
} catch {
    Write-Host $_.ErrorDetails.Message
}

Write-Host "`nHinweis: Wenn Event Log 'nimmt Verbindungen an' sagt, pg_isready aber nicht —"
Write-Host "oft Windows-Firewall/WFP/Loopback (nicht kaputte Datenbank)."
Write-Host "Nächster Schritt: Rechner-Neustart ODER WFP-Audit (Event 5157) — siehe Konzil-Antwort im Chat."
