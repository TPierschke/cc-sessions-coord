#Requires -Version 7.0
param(
  [ValidateSet('probe', 'repair-firewall', 'manual-pgctl')]
  [string]$Mode = 'probe'
)

$ErrorActionPreference = 'Stop'

$PgService = 'postgresql-x64-18'
$PgBin = 'C:\Program Files\PostgreSQL\18\bin'
$PgData = 'C:\Program Files\PostgreSQL\18\data'
$PgExe = 'C:\Program Files\PostgreSQL\18\bin\postgres.exe'
$RuleName = 'PostgreSQL 18 (TCP 5432)'
$CcscHealth = 'http://localhost:7733/health'

function Is-Admin {
  return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Print-Header([string]$text) {
  Write-Host "`n=== $text ===" -ForegroundColor Cyan
}

function Safe-Run([string]$label, [scriptblock]$block) {
  try {
    Write-Host "[OK?] $label" -ForegroundColor Gray
    & $block
  } catch {
    Write-Host "[FAIL] $label -> $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

function Get-ListenerPid {
  $conn = Get-NetTCPConnection -LocalPort 5432 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $conn) { return $null }
  return $conn.OwningProcess
}

function Probe-State {
  Print-Header 'Service + Socket'
  Safe-Run 'Service status' { Get-Service $PgService | Select-Object Status, Name, StartType | Format-Table -AutoSize }
  Safe-Run 'pg_isready 127.0.0.1:5432' { & "$PgBin\pg_isready.exe" -h 127.0.0.1 -p 5432 }
  Safe-Run 'Test-NetConnection 127.0.0.1:5432' { Test-NetConnection -ComputerName 127.0.0.1 -Port 5432 | Select-Object ComputerName, RemotePort, TcpTestSucceeded | Format-Table -AutoSize }
  Safe-Run 'Listener PID on 5432' {
    $listenerPid = Get-ListenerPid
    if ($null -eq $listenerPid) {
      Write-Host 'No LISTEN socket on 5432' -ForegroundColor Red
      return
    }
    Write-Host "Listener PID: $listenerPid"
    Get-CimInstance Win32_Process -Filter "ProcessId=$listenerPid" | Select-Object ProcessId, Name, ParentProcessId | Format-Table -AutoSize
  }

  Print-Header 'Firewall + WFP signal'
  Safe-Run 'Inbound app rules for postgres.exe' {
    $count = Get-NetFirewallRule -Enabled True -Direction Inbound |
      Get-NetFirewallApplicationFilter |
      Where-Object { $_.Program -eq $PgExe } |
      Measure-Object |
      Select-Object -ExpandProperty Count
    Write-Host "Enabled inbound app rules for postgres.exe: $count"
  }

  Safe-Run 'Loopback sanity check on temp port 55555' {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse('127.0.0.1'), 55555)
    $listener.Start()
    Start-Sleep -Milliseconds 300
    try {
      Test-NetConnection -ComputerName 127.0.0.1 -Port 55555 | Select-Object RemotePort, TcpTestSucceeded | Format-Table -AutoSize
    } finally {
      $listener.Stop()
    }
  }

  Print-Header 'Quick verdict'
  $svc = Get-Service $PgService -ErrorAction SilentlyContinue
  $listenerPid = Get-ListenerPid
  $tcp = Test-NetConnection -ComputerName 127.0.0.1 -Port 5432 -WarningAction SilentlyContinue
  if ($svc.Status -eq 'Running' -and $null -ne $listenerPid -and -not $tcp.TcpTestSucceeded) {
    Write-Host 'VERDICT: service and LISTEN exist, but loopback to 5432 is dropped/blocked before handshake.' -ForegroundColor Red
  } elseif ($svc.Status -ne 'Running') {
    Write-Host 'VERDICT: PostgreSQL service is not running.' -ForegroundColor Red
  } elseif ($null -eq $listenerPid) {
    Write-Host 'VERDICT: service claims running but no listener on 5432.' -ForegroundColor Red
  } else {
    Write-Host 'VERDICT: TCP handshake works. problem is likely auth/database side.' -ForegroundColor Green
  }
}

function Repair-Firewall {
  if (-not (Is-Admin)) {
    throw 'repair-firewall mode needs admin pwsh.'
  }
  Print-Header 'Repair firewall rule + restart service'
  $existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
  if ($null -eq $existing) {
    New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5432 -Program $PgExe -Profile Any | Out-Null
    Write-Host "Created rule: $RuleName" -ForegroundColor Green
  } else {
    Write-Host "Rule already exists: $RuleName" -ForegroundColor Yellow
  }

  Restart-Service $PgService -Force
  Start-Sleep -Seconds 2

  Safe-Run 'pg_isready after repair' { & "$PgBin\pg_isready.exe" -h 127.0.0.1 -p 5432 }
  Safe-Run 'ccsc health after repair' { Invoke-RestMethod $CcscHealth -TimeoutSec 10 | ConvertTo-Json -Depth 4 }
}

function Manual-Pgctl {
  if (-not (Is-Admin)) {
    throw 'manual-pgctl mode needs admin pwsh.'
  }
  Print-Header 'Manual pg_ctl isolation test'
  $log = "$env:TEMP\pg-manual-start-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

  Stop-Service $PgService -Force -ErrorAction SilentlyContinue
  Get-Process postgres -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 3

  $pidFile = Join-Path $PgData 'postmaster.pid'
  if (Test-Path $pidFile) {
    Remove-Item $pidFile -Force
  }

  & "$PgBin\pg_ctl.exe" start -D $PgData -l $log -w -t 60
  $startExit = $LASTEXITCODE
  Write-Host "pg_ctl start exit: $startExit"

  Safe-Run 'manual pg_isready' { & "$PgBin\pg_isready.exe" -h 127.0.0.1 -p 5432 }
  Safe-Run 'manual log tail' {
    if (Test-Path $log) {
      Get-Content $log -Tail 40
    }
  }

  & "$PgBin\pg_ctl.exe" stop -D $PgData -m fast -w -t 30 | Out-Null
  Start-Service $PgService
  Write-Host "Manual test log: $log"
}

switch ($Mode) {
  'probe' { Probe-State }
  'repair-firewall' { Repair-Firewall }
  'manual-pgctl' { Manual-Pgctl }
}
