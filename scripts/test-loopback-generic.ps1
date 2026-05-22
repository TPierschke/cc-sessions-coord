#Requires -Version 7.0
<#
  Loopback Sanity Check — ohne Postgres.
  Startet einen reinen .NET TcpListener auf einem freien Port und prueft ob Loopback ankommt.
  Plus: Test bekannter Loopback-Ports (OpenCode 12121, Dashboard 80, etc).
  Falsifiziert/verifiziert Hypothese "Loopback generell kaputt".
#>
$ErrorActionPreference = 'Continue'

function Step($t) { Write-Host ''; Write-Host ('===== ' + $t + ' =====') -ForegroundColor Cyan }

Step '1. Test bekannte Loopback-Ports (was laeuft, was nicht)'
$ports = @(
    @{ p=12121; name='OpenCode' },
    @{ p=80;    name='Lokales Dashboard' },
    @{ p=7733;  name='ccsc Worker' },
    @{ p=24842; name='Token-Optimizer Daemon' },
    @{ p=5432;  name='Postgres' }
)
foreach ($it in $ports) {
    $t = Test-NetConnection -ComputerName 127.0.0.1 -Port $it.p -WarningAction SilentlyContinue
    $col = if ($t.TcpTestSucceeded) { 'Green' } else { 'Red' }
    Write-Host (' {0,-30}  Port {1,5}  Tcp={2}' -f $it.name, $it.p, $t.TcpTestSucceeded) -ForegroundColor $col
}

Step '2. Reiner .NET TcpListener auf 13579 (kein PG, kein Treiber)'
$port = 13579
$listener = $null
try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $port)
    $listener.Start()
    Write-Host (' Listener gestartet auf 0.0.0.0:{0}' -f $port)

    Start-Sleep -Milliseconds 500

    Step '3. Listener im Kernel sichtbar?'
    Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
        Select-Object LocalAddress, LocalPort, OwningProcess

    Step '4. Test-NetConnection 127.0.0.1:13579'
    $t = Test-NetConnection -ComputerName 127.0.0.1 -Port $port -WarningAction SilentlyContinue
    Write-Host (' TcpTestSucceeded: {0}' -f $t.TcpTestSucceeded)
    $loop4 = $t.TcpTestSucceeded

    Step '5. Test-NetConnection ::1:13579'
    $t6 = Test-NetConnection -ComputerName ::1 -Port $port -WarningAction SilentlyContinue
    Write-Host (' TcpTestSucceeded: {0}' -f $t6.TcpTestSucceeded)
    $loop6 = $t6.TcpTestSucceeded

    Step '6. Raw .NET TcpClient connect (umgeht Test-NetConnection)'
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync([System.Net.IPAddress]::Loopback, $port)
        $ok = $task.Wait(3000)
        Write-Host (' TcpClient.ConnectAsync to 127.0.0.1:{0}  ok={1}  connected={2}' -f $port, $ok, $client.Connected)
        $rawOk = $client.Connected
        $client.Close()
    } catch {
        Write-Host (' TcpClient FEHLER: {0}' -f $_.Exception.Message) -ForegroundColor Red
        $rawOk = $false
    }
} finally {
    if ($listener) { $listener.Stop() }
}

Step '7. Listener-Filter (WFP + 3rd-party Network-Treiber)'
Write-Host '--- Aktive Adapter-Bindings (Netzwerk-Filter-Treiber) ---'
Get-NetAdapterBinding -ComponentID '*' -ErrorAction SilentlyContinue |
    Where-Object { $_.Enabled -and $_.Name -match 'Loopback|Default Switch|WSL' } |
    Select-Object Name, DisplayName, ComponentID

Write-Host ''
Write-Host '--- WFP-Filter (nur die mit "block" im Namen) ---'
$wfpDump = "$env:TEMP\wfp-snapshot.xml"
& netsh wfp show filters file=$wfpDump dir=in 2>&1 | Out-Null
if (Test-Path $wfpDump) {
    Select-String -Path $wfpDump -Pattern 'block|drop' -SimpleMatch -CaseSensitive:$false |
        Select-Object -First 10 |
        ForEach-Object { Write-Host (' ' + $_.Line.Trim()) }
}

Step '=== AUSWERTUNG ==='
if (-not $loop4 -and -not $loop6 -and -not $rawOk) {
    Write-Host 'LOOPBACK GENERELL KAPUTT auf dieser Maschine.' -ForegroundColor Red
    Write-Host 'Kein PG-Problem. WFP-Filter / Npcap Loopback Adapter / NDIS-Treiber.' -ForegroundColor Red
    Write-Host 'Naechster Schritt: Npcap Loopback Adapter deaktivieren + Test wiederholen.' -ForegroundColor Yellow
} elseif ($loop4 -or $rawOk) {
    Write-Host 'LOOPBACK FUNKTIONIERT (Port 13579 erreichbar).' -ForegroundColor Green
    Write-Host 'Problem ist PG-spezifisch oder portspezifisch (5432/5433).' -ForegroundColor Yellow
} else {
    Write-Host 'GEMISCHT: IPv4/IPv6/Raw verhalten sich unterschiedlich.' -ForegroundColor Yellow
}
