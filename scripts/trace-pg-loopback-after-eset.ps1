#Requires -Version 7.0
#Requires -RunAsAdministrator
<#
  Trace nach ESET-Aus: kommt der "land attack" Drop noch?
  Plus: ESET-WFP-Filter via netsh wfp listen.
#>
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$etl   = "$env:TEMP\pg-eset-off-$stamp.etl"
$txt   = "$env:TEMP\pg-eset-off-$stamp.txt"

function Step($t) { Write-Host ''; Write-Host ('===== ' + $t + ' =====') -ForegroundColor Cyan }

Step '1. pktmon Filter + Start'
& pktmon reset 2>&1 | Out-Null
& pktmon filter remove 2>&1 | Out-Null
& pktmon filter add -p 5432 2>&1 | Out-Null
& pktmon start --capture --comp all --type all --pkt-size 0 -f $etl 2>&1 | Out-Null

Step '2. pg_isready 2x'
for ($i=1; $i -le 2; $i++) {
    & 'C:\Program Files\PostgreSQL\18\bin\pg_isready.exe' -h 127.0.0.1 -p 5432 -t 2
    Start-Sleep 1
}

Step '3. pktmon Stop + ETL2TXT'
& pktmon stop 2>&1 | Out-Null
& pktmon etl2txt $etl -o $txt 2>&1 | Out-Null

Step '4. Suche "land attack" Drops im Capture'
if (Test-Path $txt) {
    $hits = Select-String -Path $txt -Pattern 'land attack' -SimpleMatch -CaseSensitive:$false
    if ($hits) {
        Write-Host (' GEFUNDEN: {0} "land attack" Drops' -f $hits.Count) -ForegroundColor Red
        $hits | Select-Object -First 5 | ForEach-Object { Write-Host ('  ' + $_.Line.Trim()) }
    } else {
        Write-Host ' KEIN "land attack" Drop mehr!' -ForegroundColor Green
        Write-Host '--- erste 30 Zeilen Drops/SYN ---'
        Select-String -Path $txt -Pattern 'Drop|TCP|SYN' -SimpleMatch | Select-Object -First 30 | ForEach-Object { Write-Host ('  ' + $_.Line.Trim()) }
    }
}

Step '5. ESET WFP-Filter aktiv?'
$wfp = "$env:TEMP\wfp-snapshot-$stamp.xml"
& netsh wfp show filters file=$wfp 2>&1 | Out-Null
if (Test-Path $wfp) {
    $eset = Select-String -Path $wfp -Pattern 'ESET|epfw|EpfwWFP' -CaseSensitive:$false
    if ($eset) {
        Write-Host (' ESET-WFP-Filter im Kernel: {0} Treffer' -f $eset.Count) -ForegroundColor Red
        $eset | Select-Object -First 8 | ForEach-Object { Write-Host ('  ' + $_.Line.Trim()) }
    } else {
        Write-Host ' Keine ESET-Filter im WFP-Dump.' -ForegroundColor Green
    }
}

Step '6. Anderer Port: PG auf 15432 nachstellen mit reinem .NET-Listener'
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, 15432)
$listener.Start()
Start-Sleep 1
$t = Test-NetConnection 127.0.0.1 -Port 15432 -WarningAction SilentlyContinue
Write-Host (' 127.0.0.1:15432 (.NET-Listener auf 0.0.0.0): {0}' -f $t.TcpTestSucceeded)
$listener.Stop()

Step '7. Nochmal 5432-Bind-Test mit reinem .NET (NICHT PG)'
try {
    $l2 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, 5432)
} catch {
    Write-Host (' Port 5432 wird von PG belegt - skip.')
    return
}
