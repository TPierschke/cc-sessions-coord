#Requires -Version 7.0
<#
  Systematischer Test: Postgres OHNE Windows-Dienst starten (pg_ctl direkt).
  Trennt "postgres kaputt" vs "Dienst-Wrapper kaputt".

  <repo-root>\scripts\test-pg-manual-pgctl.ps1
#>
$ErrorActionPreference = 'Stop'
$PgBin = 'C:\Program Files\PostgreSQL\18\bin'
$PgData = 'C:\Program Files\PostgreSQL\18\data'
$PgService = 'postgresql-x64-18'
$LogFile = "$env:TEMP\pg-manual-start-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'FEHLER: Als Administrator ausführen.' -ForegroundColor Red
    exit 1
}

Write-Host "Log: $LogFile" -ForegroundColor Gray

Write-Host "`n[1] Windows-Dienst stoppen + postgres.exe killen" -ForegroundColor Cyan
Stop-Service $PgService -Force -ErrorAction SilentlyContinue
Get-Process postgres -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 5

$pidFile = Join-Path $PgData 'postmaster.pid'
if (Test-Path $pidFile) {
    Write-Host "[2] postmaster.pid entfernen (kein laufender postmaster)" -ForegroundColor Cyan
    Remove-Item $pidFile -Force
}

Write-Host "[3] pg_ctl start (manuell, nicht als Dienst)" -ForegroundColor Cyan
& "$PgBin\pg_ctl.exe" start -D $PgData -l $LogFile -w -t 60
$startExit = $LASTEXITCODE
Write-Host "  pg_ctl start exit=$startExit"

Write-Host "`n[4] Log (letzte 20 Zeilen)" -ForegroundColor Cyan
if (Test-Path $LogFile) { Get-Content $LogFile -Tail 20 } else { Write-Host '  (keine Logdatei)' }

Write-Host "`n[5] pg_ctl status" -ForegroundColor Cyan
& "$PgBin\pg_ctl.exe" status -D $PgData 2>&1

Write-Host "`n[6] pg_isready" -ForegroundColor Cyan
& "$PgBin\pg_isready.exe" -h 127.0.0.1 -p 5432 2>&1
$readyExit = $LASTEXITCODE

Write-Host "`n[7] pg_ctl stop" -ForegroundColor Cyan
& "$PgBin\pg_ctl.exe" stop -D $PgData -m fast -w -t 30 2>&1

Write-Host "`n=== Auswertung ===" -ForegroundColor Yellow
if ($readyExit -eq 0) {
    Write-Host 'MANUELL OK -> Problem liegt am Windows-Dienst/Konto/Startpfad, nicht an den Daten.' -ForegroundColor Green
    Write-Host 'Nächster Schritt: Dienst-Konto/Recovery in postgresql.conf prüfen (postgresql-x64-18).'
} else {
    Write-Host 'MANUELL AUCH KAPUTT -> Datenverzeichnis, Postgres-Binary oder OS/TCP-Stack.' -ForegroundColor Red
    Write-Host 'Nächster Schritt: Postgres-Install reparieren oder Daten auf andere Instanz migrieren.'
}

exit $readyExit
