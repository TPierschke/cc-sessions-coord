#Requires -Version 7.0
#Requires -RunAsAdministrator
<#
  pktmon-Trace: capture Loopback-Pakete waehrend pg_isready-Connect.
  Zeigt ECHTE TCP-Wahrheit: kommt SYN an? wird SYN-ACK gesendet? droppt was?
#>
$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$etl   = "$env:TEMP\pg-loopback-$stamp.etl"
$txt   = "$env:TEMP\pg-loopback-$stamp.txt"
$drop  = "$env:TEMP\pg-loopback-drops-$stamp.txt"

function Step($t) { Write-Host ''; Write-Host ('===== ' + $t + ' =====') -ForegroundColor Cyan }

Step '1. pktmon reset + Filter auf Port 5432'
& pktmon reset 2>&1 | Out-Null
& pktmon filter remove 2>&1 | Out-Null
& pktmon filter add -p 5432 2>&1 | Out-Null

Step '2. pktmon Start (mit Drop-Reporting)'
& pktmon start --capture --comp all --type all --pkt-size 0 -f $etl 2>&1
Start-Sleep 1

Step '3. pg_isready 3x (provoziert SYNs)'
for ($i=1; $i -le 3; $i++) {
    Write-Host (' Versuch ' + $i + ':')
    & "C:\Program Files\PostgreSQL\18\bin\pg_isready.exe" -h 127.0.0.1 -p 5432 -t 2
    Start-Sleep 1
}

Step '4. pktmon Stop'
& pktmon stop 2>&1
Start-Sleep 1

Step '5. ETL -> Text'
& pktmon etl2txt $etl -o $txt 2>&1 | Out-Null
& pktmon list --counters 2>&1 > $drop

Step '6. Capture-Inhalt (erste 60 Zeilen, Drop-Counter)'
Write-Host '--- Pakete ---'
if (Test-Path $txt) {
    Get-Content $txt -TotalCount 60
} else {
    Write-Host '(keine txt-Datei)'
}
Write-Host ''
Write-Host '--- Drop-Counter pro Komponente ---'
if (Test-Path $drop) {
    Get-Content $drop | Select-String -Pattern 'Component|Drop|Block' -SimpleMatch
}

Step '=== Dateien ==='
Write-Host (' ETL: ' + $etl)
Write-Host (' TXT: ' + $txt)
Write-Host (' Counters: ' + $drop)
Write-Host ''
Write-Host 'Schick mir den txt-Inhalt + Drop-Counter, dann sehen wir definitiv WO der SYN versumpft.'
