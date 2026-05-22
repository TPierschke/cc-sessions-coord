#Requires -Version 7.0
#Requires -RunAsAdministrator
<#
  Test ob PG-Daten OK sind UND Port 5432 spezifisch blockiert.
  Startet PG auf Port 5433 mit denselben Daten und prueft Erreichbarkeit.
  Wenn 5433 OK -> spezifisch Port 5432 wird abgefangen (WFP, Hyper-V, etc).
  Wenn 5433 auch tot -> tiefer TCP-Stack-Bug.
#>
$ErrorActionPreference = 'Continue'
$PgBin   = 'C:\Program Files\PostgreSQL\18\bin'
$PgData  = 'C:\Program Files\PostgreSQL\18\data'
$PgSvc   = 'postgresql-x64-18'
$LogFile = "$env:TEMP\pg-port5433-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Step($t) { Write-Host ''; Write-Host ('===== ' + $t + ' =====') -ForegroundColor Cyan }

Step '1. Dienst stoppen + postgres.exe killen'
Stop-Service $PgSvc -Force -ErrorAction SilentlyContinue
Get-Process postgres -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 5
Remove-Item (Join-Path $PgData 'postmaster.pid') -Force -ErrorAction SilentlyContinue

Step '2. pg_ctl start auf Port 5433 (Options ueber -o)'
& "$PgBin\pg_ctl.exe" start -D $PgData -l $LogFile -w -t 60 -o '-p 5433'
Write-Host ('pg_ctl start exit=' + $LASTEXITCODE)

Step '3. Listener auf 5433?'
Get-NetTCPConnection -LocalPort 5433 -State Listen -ErrorAction SilentlyContinue | Select-Object LocalAddress,LocalPort,OwningProcess

Step '4. pg_isready -p 5433'
& "$PgBin\pg_isready.exe" -h 127.0.0.1 -p 5433
$ready5433 = $LASTEXITCODE
Write-Host ('pg_isready -p 5433 exit=' + $ready5433)

Step '5. Test-NetConnection 127.0.0.1:5433'
$tcp = Test-NetConnection -ComputerName 127.0.0.1 -Port 5433 -WarningAction SilentlyContinue
Write-Host ('TcpTestSucceeded 5433: ' + $tcp.TcpTestSucceeded)

Step '6. Vergleich: TcpTestSucceeded 127.0.0.1:5432 (sollte False bleiben)'
$tcp5432 = Test-NetConnection -ComputerName 127.0.0.1 -Port 5432 -WarningAction SilentlyContinue
Write-Host ('TcpTestSucceeded 5432: ' + $tcp5432.TcpTestSucceeded)

Step '7. Log (letzte 20)'
if (Test-Path $LogFile) { Get-Content $LogFile -Tail 20 }

Step '8. Aufraeumen: pg_ctl stop'
& "$PgBin\pg_ctl.exe" stop -D $PgData -m fast -w -t 30 2>&1 | Out-Null

Step '=== AUSWERTUNG ==='
if ($ready5433 -eq 0) {
    Write-Host 'PORT 5433 OK -> PG und Daten sind in Ordnung.' -ForegroundColor Green
    Write-Host 'Diagnose: spezifisch Port 5432 wird auf Loopback abgefangen.' -ForegroundColor Green
    Write-Host 'Verdaechtige: WFP-Filter, Hyper-V Switch-Extension, 3rd-party-Treiber.' -ForegroundColor Yellow
    Write-Host 'Naechster Schritt: netsh wfp show filters file=wfp.xml -> Filter analysieren.' -ForegroundColor Yellow
} else {
    Write-Host 'PORT 5433 AUCH TOT -> TCP-Stack-Bug auf System-Ebene.' -ForegroundColor Red
    Write-Host 'Verdaechtige: AFD.sys-Update, korrupter TCP/IP-Stack.' -ForegroundColor Yellow
    Write-Host 'Naechster Schritt: netsh int ip reset (braucht Reboot) oder Sfc /scannow.' -ForegroundColor Yellow
}

exit $ready5433
