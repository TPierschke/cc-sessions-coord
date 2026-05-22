# Ping-Pong T86 <-> T87 — coord_exec_dialog / coord_exec_response
# Wartet auf DB-Einträge (= Tool hat in der Session gefeuert). SQL-Fallback nur nach Timeout.
#Requires -Version 7.0
$ErrorActionPreference = 'Stop'

$T86_NAME = 'T86'
$T87_NAME = 'T87'
$T86_PORT = 45777
$T87_PORT = 45780
$T86_SHORT = '3e16d911'
$T87_SHORT = 'd69950f5'
$TOOL_WAIT_SEC = 75

$psql = if ($env:PSQL_PATH) { $env:PSQL_PATH } else { 'psql' }
if (-not $env:PGPASSWORD) { $env:PGPASSWORD = $env:CCSC_PG_PASSWORD }
if (-not $env:PGPASSWORD) { throw 'Set PGPASSWORD or CCSC_PG_PASSWORD before running this script.' }

function Invoke-Pg([string]$Sql) {
  $out = & $psql -h localhost -U ccsc_bridge -d cc_sessions_coord -t -A -c $Sql 2>&1
  if ($LASTEXITCODE -ne 0) { throw "psql: $out" }
  return @($out | Where-Object { $_ -and $_.Trim() -ne '' })
}

function Send-ChannelInject([int]$Port, [string]$Message) {
  $body = @{
    channel           = 'ccsc'
    payload           = $Message
    injection_id      = "pp-$(Get-Date -Format 'HHmmss-fff')"
    kind              = 'inject'
    priority          = 10
    source_session_id = 'cursor-pingpong'
  } | ConvertTo-Json -Compress
  $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/inject" -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 15 -UseBasicParsing
  if ($r.StatusCode -ne 202) { throw "inject port $Port -> HTTP $($r.StatusCode)" }
}

function Wait-NewInjection {
  param(
    [string]$SourceShort,
    [string]$TargetShort,
    [string]$Kind,
    [int]$AfterId,
    [int]$TimeoutSec = $TOOL_WAIT_SEC
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    $rows = Invoke-Pg @"
SELECT id, inject_text FROM coord.injections
 WHERE id > $AfterId
   AND source_short_id = '$SourceShort'
   AND target_short_id = '$TargetShort'
   AND kind = '$Kind'
 ORDER BY id ASC LIMIT 1;
"@
    if ($rows.Count -ge 1) {
      $parts = $rows[0] -split '\|', 2
      return @{ id = [int]$parts[0]; inject_text = $parts[1] }
    }
    Start-Sleep -Seconds 2
  }
  return $null
}

function Wait-ExecResponse([string]$WaitInTargetShort, [int]$ReplyToDialogId, [int]$AfterId, [int]$TimeoutSec = $TOOL_WAIT_SEC) {
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    $rows = Invoke-Pg @"
SELECT id FROM coord.injections
 WHERE id > $AfterId
   AND target_short_id = '$WaitInTargetShort'
   AND kind = 'exec_response'
   AND reply_to_injection_id = $ReplyToDialogId
 ORDER BY id ASC LIMIT 1;
"@
    if ($rows) { return [int]$rows[0] }
    Start-Sleep -Seconds 2
  }
  return $null
}

function Get-MaxInjectionId() {
  $r = Invoke-Pg 'SELECT COALESCE(MAX(id),0) FROM coord.injections;'
  return [int]$r[0]
}

function Sql-Dialog([string]$SourceShort, [string]$TargetShort, [int]$Round, [string]$Dir) {
  $dialogId = [guid]::NewGuid().ToString()
  $inner = (@{ dialog_id = $dialogId; payload = "Fallback R$Round $Dir $(Get-Date -Format 'HH:mm:ss')" } | ConvertTo-Json -Compress).Replace("'", "''")
  $id = [int](Invoke-Pg "INSERT INTO coord.injections (source_short_id, target_short_id, inject_text, kind, priority, expects_reply) VALUES ('$SourceShort', '$TargetShort', '$inner', 'exec_dialog', 10, true) RETURNING id;")[0]
  return @{ id = $id; dialog_id = $dialogId }
}

function Sql-Response([string]$SourceShort, [string]$TargetShort, [string]$DialogId, [int]$ReplyToId, [int]$Round, [string]$Dir) {
  $inner = (@{ dialog_id = $DialogId; status = 'ok'; payload = "Fallback Antwort R$Round $Dir" } | ConvertTo-Json -Compress).Replace("'", "''")
  return [int](Invoke-Pg "INSERT INTO coord.injections (source_short_id, target_short_id, inject_text, kind, priority, expects_reply, reply_to_injection_id) VALUES ('$SourceShort', '$TargetShort', '$inner', 'exec_response', 10, false, $ReplyToId) RETURNING id;")[0]
}

function Parse-DialogId([string]$InjectText) {
  try {
    $o = $InjectText | ConvertFrom-Json
    return [string]$o.dialog_id
  } catch { return [guid]::NewGuid().ToString() }
}

$baseline = Get-MaxInjectionId
Write-Host "=== Ping-Pong T86 <-> T87 ===" -ForegroundColor Green
Write-Host "Baseline injection id: $baseline"

# ---- Runde 1: T86 dialog, T87 response, warten in T86 ----
Write-Host "`n[Runde 1/5] T86 coord_exec_dialog -> T87 coord_exec_response" -ForegroundColor Yellow
$mark = Get-MaxInjectionId
Send-ChannelInject $T86_PORT @"
PINGPONG 1/5 — Nur coord_exec_dialog: target=$T87_NAME, payload='R1 T86 zu T87 $(Get-Date -Format 'HH:mm:ss')'. Kein anderer Text.
"@

$d1 = Wait-NewInjection -SourceShort $T86_SHORT -TargetShort $T87_SHORT -Kind 'exec_dialog' -AfterId $mark
if (-not $d1) {
  Write-Host "  Tool-Timeout dialog -> SQL-Fallback" -ForegroundColor DarkYellow
  $d1 = Sql-Dialog $T86_SHORT $T87_SHORT 1 'T86->T87'
  $d1 = @{ id = $d1.id; inject_text = "{}" }
}
$dialogId1 = Parse-DialogId $d1.inject_text
Write-Host "  Dialog #$($d1.id) (T86->T87)" -ForegroundColor Cyan

$mark2 = Get-MaxInjectionId
Send-ChannelInject $T87_PORT @"
PINGPONG 1/5 — Nur coord_exec_response: target=$T86_NAME, reply_to_injection_id=$($d1.id), dialog_id=$dialogId1, payload='Antwort R1', status=ok
"@

$r1 = Wait-ExecResponse -WaitInTargetShort $T86_SHORT -ReplyToDialogId $d1.id -AfterId $mark2
if (-not $r1) {
  Write-Host "  Tool-Timeout response -> SQL-Fallback" -ForegroundColor DarkYellow
  $r1 = Sql-Response $T87_SHORT $T86_SHORT $dialogId1 $d1.id 1 'T87->T86'
}
Write-Host "  exec_response #$r1 in T86 — weiter." -ForegroundColor Green

# ---- Runden 2-5: T87 dialog, T86 response, warten in T87 ----
for ($n = 2; $n -le 5; $n++) {
  Write-Host "`n[Runde $n/5] T87 coord_exec_dialog -> T86 coord_exec_response" -ForegroundColor Yellow
  $mark = Get-MaxInjectionId
  Send-ChannelInject $T87_PORT @"
PINGPONG $n/5 — Nur coord_exec_dialog: target=$T86_NAME, payload='R$n T87 zu T86 $(Get-Date -Format 'HH:mm:ss')'. Kein anderer Text.
"@

  $dn = Wait-NewInjection -SourceShort $T87_SHORT -TargetShort $T86_SHORT -Kind 'exec_dialog' -AfterId $mark
  if (-not $dn) {
    Write-Host "  Tool-Timeout dialog -> SQL-Fallback" -ForegroundColor DarkYellow
    $fb = Sql-Dialog $T87_SHORT $T86_SHORT $n 'T87->T86'
    $dn = @{ id = $fb.id; inject_text = '{}' }
  }
  $dialogIdN = Parse-DialogId $dn.inject_text
  Write-Host "  Dialog #$($dn.id) (T87->T86)" -ForegroundColor Cyan

  $mark2 = Get-MaxInjectionId
  Send-ChannelInject $T86_PORT @"
PINGPONG $n/5 — Nur coord_exec_response: target=$T87_NAME, reply_to_injection_id=$($dn.id), dialog_id=$dialogIdN, payload='Antwort R$n', status=ok
"@

  $rn = Wait-ExecResponse -WaitInTargetShort $T87_SHORT -ReplyToDialogId $dn.id -AfterId $mark2
  if (-not $rn) {
    Write-Host "  Tool-Timeout response -> SQL-Fallback" -ForegroundColor DarkYellow
    $rn = Sql-Response $T86_SHORT $T87_SHORT $dialogIdN $dn.id $n 'T86->T87'
  }
  Write-Host "  exec_response #$rn in T87 — weiter." -ForegroundColor Green
}

Write-Host "`n=== PINGPONG 5/5 FERTIG ===" -ForegroundColor Green
