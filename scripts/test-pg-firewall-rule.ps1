# Test ob eine Inbound-Allow-Regel fuer postgres.exe/TCP 5432 das Loopback-Problem fixt.
# Bei FAIL: Rollback der Regel.
# Pflicht: Admin-pwsh.

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Continue'
$ruleName = 'PostgreSQL 18 (TCP 5432) - TEST 2026-05-19'
$pgExe    = 'C:\Program Files\PostgreSQL\18\bin\postgres.exe'
$pgReady  = 'C:\Program Files\PostgreSQL\18\bin\pg_isready.exe'
$svc      = 'postgresql-x64-18'

function Write-Section($t) { Write-Host ''; Write-Host ('=' * 60) -ForegroundColor Cyan; Write-Host $t -ForegroundColor Cyan; Write-Host ('=' * 60) -ForegroundColor Cyan }

Write-Section '1. Vorzustand'
& $pgReady -h 127.0.0.1 -p 5432
$preExit = $LASTEXITCODE
Write-Host ('pg_isready Exit vorher: {0}' -f $preExit)

Write-Section '2. Lege FW-Allow-Regel an (idempotent)'
$existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host 'Regel existiert bereits, ueberspringe.'
} else {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort 5432 -Program $pgExe -Profile Any | Out-Null
    Write-Host 'Regel angelegt.'
}

Write-Section '3. Restart-Service postgresql-x64-18'
Restart-Service $svc -Force
Start-Sleep -Seconds 8

Write-Section '4. Test nach Restart'
& $pgReady -h 127.0.0.1 -p 5432
$postExit = $LASTEXITCODE
$tcp = Test-NetConnection -ComputerName 127.0.0.1 -Port 5432 -WarningAction SilentlyContinue
Write-Host ('pg_isready Exit nachher: {0}' -f $postExit)
Write-Host ('TcpTestSucceeded:        {0}' -f $tcp.TcpTestSucceeded)

Write-Section '5. Befund + Rollback-Entscheidung'
if ($postExit -eq 0) {
    Write-Host 'ERFOLG: pg_isready akzeptiert Verbindungen.' -ForegroundColor Green
    Write-Host 'Regel BLEIBT (User entscheidet ob umbenennen nach TEST-Ende).' -ForegroundColor Green
    exit 0
} else {
    Write-Host 'FEHLSCHLAG: pg_isready meldet weiter keine Antwort.' -ForegroundColor Yellow
    Write-Host 'Rolle FW-Regel zurueck...' -ForegroundColor Yellow
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    Write-Host 'Regel entfernt. Hypothese "FW blockiert" falsifiziert.' -ForegroundColor Yellow
    Write-Host 'Naechster Schritt: Skript B (test-pg-manual-pgctl.ps1) fuer pg_ctl-Start mit Logfile.' -ForegroundColor Yellow
    exit 1
}
