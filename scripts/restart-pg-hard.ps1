#Requires -Version 7.0
<#
.SYNOPSIS
  PostgreSQL 18 hart neu starten (Dienst + alle postgres.exe beenden).

  Voller Pfad:
    <repo-root>\scripts\restart-pg-hard.ps1

.EXAMPLE
  pwsh -NoProfile -ExecutionPolicy Bypass -File "<repo-root>\scripts\restart-pg-hard.ps1"
#>
[CmdletBinding()]
param(
    [int] $ReadyTimeoutSec = 30
)

$ErrorActionPreference = 'Stop'
$PgService = 'postgresql-x64-18'
$PgIsReady = 'C:\Program Files\PostgreSQL\18\bin\pg_isready.exe'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'FEHLER: Als Administrator ausführen.' -ForegroundColor Red
    exit 1
}

Write-Host '==> PostgreSQL-Dienst stoppen' -ForegroundColor Cyan
Stop-Service -Name $PgService -Force -ErrorAction SilentlyContinue

Write-Host '==> Alle postgres.exe beenden' -ForegroundColor Cyan
Get-Process -Name postgres -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  PID $($_.Id)"
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}

Write-Host '==> Warten 5s' -ForegroundColor Cyan
Start-Sleep -Seconds 5

$left = Get-Process -Name postgres -ErrorAction SilentlyContinue
if ($left) {
    Write-Host 'WARNUNG: postgres.exe läuft noch:' -ForegroundColor Yellow
    $left | Format-Table Id, ProcessName -AutoSize
}

Write-Host '==> PostgreSQL-Dienst starten' -ForegroundColor Cyan
Start-Service -Name $PgService

Write-Host '==> pg_isready 127.0.0.1:5432' -ForegroundColor Cyan
$ok = $false
$deadline = (Get-Date).AddSeconds($ReadyTimeoutSec)
while ((Get-Date) -lt $deadline) {
    $out = & $PgIsReady -h 127.0.0.1 -p 5432 2>&1 | Out-String
    Write-Host "  $($out.Trim())"
    if ($LASTEXITCODE -eq 0) { $ok = $true; break }
    Start-Sleep -Seconds 2
}

if ($ok) {
    Write-Host 'Postgres: OK' -ForegroundColor Green
    exit 0
}

Write-Host 'FEHLER: Postgres antwortet nicht.' -ForegroundColor Red
exit 1
