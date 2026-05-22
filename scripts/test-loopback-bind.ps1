$port1 = 13580
$port2 = 13581
$l1 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $port1)
$l2 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port2)
$l1.Start()
$l2.Start()
Start-Sleep -Milliseconds 300
Write-Host '--- Listener registriert ---'
Get-NetTCPConnection -LocalPort $port1, $port2 -State Listen -EA SilentlyContinue | Select-Object LocalAddress, LocalPort
Write-Host ''
Write-Host ('--- Test 127.0.0.1:{0} (Listener auf 0.0.0.0) ---' -f $port1)
(Test-NetConnection 127.0.0.1 -Port $port1 -WarningAction SilentlyContinue).TcpTestSucceeded
Write-Host ('--- Test 127.0.0.1:{0} (Listener auf 127.0.0.1 explicit) ---' -f $port2)
(Test-NetConnection 127.0.0.1 -Port $port2 -WarningAction SilentlyContinue).TcpTestSucceeded
$l1.Stop()
$l2.Stop()
