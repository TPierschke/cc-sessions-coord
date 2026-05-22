#Requires -Version 7.0
#Requires -RunAsAdministrator
<#
  Schaltet PG-listen_addresses von '*' auf '0.0.0.0' (IPv4-only, kein IPv6-Dualstack).
  Begruendung: in Loopback-Test war pures 0.0.0.0-Bind erreichbar, dual-stack '*' nicht.
  Sicher: Backup der Conf vorher, automatischer Rollback wenn pg_isready scheitert.
#>
$ErrorActionPreference = 'Continue'

$PgData = 'C:\Program Files\PostgreSQL\18\data'
$PgBin  = 'C:\Program Files\PostgreSQL\18\bin'
$Conf   = Join-Path $PgData 'postgresql.conf'
$svc    = 'postgresql-x64-18'
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$bak    = "$Conf.bak-$stamp"

function Step($t) { Write-Host ''; Write-Host ('===== ' + $t + ' =====') -ForegroundColor Cyan }

Step '1. Vorzustand: aktueller listen_addresses-Eintrag'
$current = Select-String -Path $Conf -Pattern '^\s*listen_addresses' -CaseSensitive:$false
$current | ForEach-Object { Write-Host (' ' + $_.Line) }

Step '2. Backup nach postgresql.conf.bak-<stamp>'
Copy-Item -Path $Conf -Destination $bak -Force
Write-Host (' Backup: ' + $bak)

Step '3. listen_addresses auf 0.0.0.0 setzen (nur IPv4-wildcard)'
$lines = Get-Content -LiteralPath $Conf
$newLines = foreach ($l in $lines) {
    if ($l -match "^\s*listen_addresses\s*=") {
        "listen_addresses = '0.0.0.0'                # TEST 2026-05-19 (war: '*')"
    } else { $l }
}
Set-Content -LiteralPath $Conf -Value $newLines
Select-String -Path $Conf -Pattern '^\s*listen_addresses' -CaseSensitive:$false | ForEach-Object { Write-Host (' Neu: ' + $_.Line) }

Step '4. Service Restart'
Stop-Service $svc -Force -ErrorAction SilentlyContinue
Get-Process postgres -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 4
Remove-Item (Join-Path $PgData 'postmaster.pid') -Force -ErrorAction SilentlyContinue
Start-Service $svc
Start-Sleep 8

Step '5. Listener-Bindings (sollte nur 0.0.0.0:5432 sein, kein [::])'
Get-NetTCPConnection -LocalPort 5432 -State Listen -EA SilentlyContinue | Select-Object LocalAddress, LocalPort, OwningProcess

Step '6. pg_isready'
& "$PgBin\pg_isready.exe" -h 127.0.0.1 -p 5432
$ready = $LASTEXITCODE
Write-Host (' pg_isready exit=' + $ready)

Step '7. Test-NetConnection 127.0.0.1:5432'
$tcp = Test-NetConnection -ComputerName 127.0.0.1 -Port 5432 -WarningAction SilentlyContinue
Write-Host (' TcpTestSucceeded: ' + $tcp.TcpTestSucceeded)

Step '8. Worker /health (falls Worker konfiguriert ist)'
try {
    $r = Invoke-WebRequest -Uri 'http://localhost:7733/health' -TimeoutSec 5 -UseBasicParsing
    Write-Host (' Worker HTTP ' + $r.StatusCode)
} catch {
    Write-Host (' Worker down: ' + $_.Exception.Message)
}

Step '=== AUSWERTUNG ==='
if ($ready -eq 0) {
    Write-Host 'PG ANTWORTET. Dual-Stack-Bind war die Ursache.' -ForegroundColor Green
    Write-Host ('Backup bleibt liegen: ' + $bak) -ForegroundColor Green
    Write-Host 'Bei Bedarf zurueck auf "*": Conf wiederherstellen + Restart-Service.' -ForegroundColor Yellow
    exit 0
} else {
    Write-Host 'PG ANTWORTET WEITER NICHT. Rollback auf alte Conf...' -ForegroundColor Red
    Copy-Item -Path $bak -Destination $Conf -Force
    Stop-Service $svc -Force -ErrorAction SilentlyContinue
    Get-Process postgres -EA SilentlyContinue | Stop-Process -Force
    Start-Sleep 4
    Remove-Item (Join-Path $PgData 'postmaster.pid') -Force -ErrorAction SilentlyContinue
    Start-Service $svc
    Write-Host (' Rollback OK. Original-Conf wiederhergestellt.') -ForegroundColor Yellow
    exit 1
}
