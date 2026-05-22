#Requires -Version 7.0
<#
.SYNOPSIS
  Postgres + cc-sessions-coord Worker sauber neu starten und prüfen.

.DESCRIPTION
  Behebt typischen Zustand: Dienst "Running", aber 127.0.0.1:5432 / :7733/health tot.
  Admin-PowerShell nötig.

  Voller Pfad:
    <repo-root>\scripts\restart-ccsc-stack.ps1

.EXAMPLE
  pwsh -NoProfile -ExecutionPolicy Bypass -File "<repo-root>\scripts\restart-ccsc-stack.ps1"
#>
[CmdletBinding()]
param(
    [switch] $SkipNodeKill,
    [int] $PgReadyTimeoutSec = 30,
    [int] $HealthTimeoutSec = 15
)

$ErrorActionPreference = 'Stop'

$PgBin      = 'C:\Program Files\PostgreSQL\18\bin'
$PgData     = 'C:\Program Files\PostgreSQL\18\data'
$PgIsReady  = Join-Path $PgBin 'pg_isready.exe'
$PgService  = 'postgresql-x64-18'
$CcscService = 'DT - cc-sessions-coord'
$HealthUrl  = 'http://127.0.0.1:7733/health'

function Write-Step([string]$Text) {
    Write-Host "`n==> $Text" -ForegroundColor Cyan
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host 'FEHLER: Als Administrator ausführen (Rechtsklick PowerShell -> Als Administrator).' -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $PgIsReady)) {
    Write-Host "FEHLER: pg_isready nicht gefunden: $PgIsReady" -ForegroundColor Red
    exit 1
}

Write-Step 'ccsc-Worker stoppen'
Stop-Service -Name $CcscService -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

if (-not $SkipNodeKill) {
    Write-Step 'Node-Prozesse mit offener PG-Verbindung (Port 5432) beenden'
    $killed = 0
    Get-Process -Name node -ErrorAction SilentlyContinue | ForEach-Object {
        $nodePid = $_.Id
        $on5432 = Get-NetTCPConnection -OwningProcess $nodePid -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -eq 5432 -or $_.RemotePort -eq 5432 }
        if ($on5432) {
            Write-Host "  stoppe node PID $nodePid"
            Stop-Process -Id $nodePid -Force -ErrorAction SilentlyContinue
            $killed++
        }
    }
    if ($killed -eq 0) { Write-Host '  (keine node-Prozesse auf 5432)' }
    Start-Sleep -Seconds 2
}

Write-Step "PostgreSQL stoppen ($PgService)"
Stop-Service -Name $PgService -Force
Start-Sleep -Seconds 5

$stillListening = netstat -ano | Select-String ':5432\s'
if ($stillListening) {
    Write-Host 'WARNUNG: Port 5432 noch belegt:' -ForegroundColor Yellow
    $stillListening | Select-Object -First 6 | ForEach-Object { Write-Host "  $_" }
}

Write-Step "PostgreSQL starten ($PgService)"
Start-Service -Name $PgService
Start-Sleep -Seconds 3

Write-Step 'pg_isready (127.0.0.1:5432)'
$ready = $false
$deadline = (Get-Date).AddSeconds($PgReadyTimeoutSec)
while ((Get-Date) -lt $deadline) {
    $out = & $PgIsReady -h 127.0.0.1 -p 5432 2>&1 | Out-String
    Write-Host "  $out".Trim()
    if ($LASTEXITCODE -eq 0 -and $out -match 'accepting|annahme') {
        $ready = $true
        break
    }
    Start-Sleep -Seconds 2
}

if (-not $ready) {
    Write-Host 'FEHLER: Postgres antwortet nicht auf 127.0.0.1:5432' -ForegroundColor Red
    $logDir = Join-Path $PgData 'log'
    $latest = Get-ChildItem $logDir -Filter 'postgresql-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        Write-Host "Letzte Logzeilen: $($latest.FullName)" -ForegroundColor Yellow
        Get-Content $latest.FullName -Tail 15
    }
    exit 2
}

Write-Host 'Postgres: OK' -ForegroundColor Green

Write-Step "ccsc-Worker starten ($CcscService)"
Start-Service -Name $CcscService
Start-Sleep -Seconds 3

Write-Step "Health $HealthUrl"
try {
    $health = Invoke-RestMethod -Uri $HealthUrl -TimeoutSec $HealthTimeoutSec
    $health | ConvertTo-Json -Compress | Write-Host
    Write-Host 'ccsc-Worker: OK' -ForegroundColor Green
} catch {
    Write-Host "FEHLER: Health — $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
    exit 3
}

Write-Host "`nFertig. In Claude-Code: /mcp reconnect, dann coord_whoami testen." -ForegroundColor Green
exit 0
