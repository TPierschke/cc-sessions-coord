param(
  [string]$BasePath = (Join-Path $env:USERPROFILE '.claude\projects'),
  [int]$RunSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $BasePath)) {
  Write-Error "BasePath not found: $BasePath"
}

Write-Host "JSONL ALARM ACTIVE" -ForegroundColor Red
Write-Host "Watching: $BasePath" -ForegroundColor Yellow
if ($RunSeconds -gt 0) {
  Write-Host "Auto-stop after $RunSeconds seconds." -ForegroundColor Yellow
} else {
  Write-Host "Run until Ctrl+C." -ForegroundColor Yellow
}
Write-Host ""

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $BasePath
$watcher.Filter = "*.jsonl"
$watcher.IncludeSubdirectories = $true
$watcher.EnableRaisingEvents = $true

function Get-ForensicSummary {
  param([string]$Path)

  $summary = [ordered]@{
    path = $Path
    kind = "main"
    sessionId = ""
    customTitle = ""
    agentName = ""
    entrypoint = ""
    cwd = ""
    hasChannelMessage = $false
    hasQueueOperation = $false
    hasBridgeStatus = $false
    hasSidechainMarker = $false
  }

  $name = [System.IO.Path]::GetFileName($Path)
  if ($name -like "agent-*.jsonl") {
    $summary.kind = "agent"
  }

  Start-Sleep -Milliseconds 120

  try {
    $lines = Get-Content -LiteralPath $Path -TotalCount 220 -ErrorAction Stop
  } catch {
    return $summary
  }

  foreach ($line in $lines) {
    if (-not $summary.sessionId -and $line -match '"sessionId":"([^"]+)"') {
      $summary.sessionId = $Matches[1]
    }
    if (-not $summary.customTitle -and $line -match '"type":"custom-title".*"customTitle":"([^"]*)"') {
      $summary.customTitle = $Matches[1]
    }
    if (-not $summary.agentName -and $line -match '"type":"agent-name".*"agentName":"([^"]*)"') {
      $summary.agentName = $Matches[1]
    }
    if (-not $summary.entrypoint -and $line -match '"entrypoint":"([^"]*)"') {
      $summary.entrypoint = $Matches[1]
    }
    if (-not $summary.cwd -and $line -match '"cwd":"([^"]*)"') {
      $summary.cwd = $Matches[1]
    }
    if ($line -match '"origin":\{"kind":"channel"') {
      $summary.hasChannelMessage = $true
    }
    if ($line -match '"type":"queue-operation"') {
      $summary.hasQueueOperation = $true
    }
    if ($line -match '"subtype":"bridge_status"') {
      $summary.hasBridgeStatus = $true
    }
    if ($line -match '"isSidechain":true|"content":"Warmup"') {
      $summary.hasSidechainMarker = $true
    }
  }

  return $summary
}

$handler = {
  param($Sender, $EventArgs)
  $path = $EventArgs.FullPath
  $name = $EventArgs.Name
  $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
  $summary = Get-ForensicSummary -Path $path

  [console]::Beep(1600, 220)
  [console]::Beep(900, 220)

  Write-Host ""
  Write-Host "!!!!!!!!!! JSONL ALARM !!!!!!!!!!" -ForegroundColor White -BackgroundColor Red
  Write-Host "[$now] NEW FILE: $name" -ForegroundColor Red
  Write-Host "Path: $($summary.path)" -ForegroundColor DarkYellow
  Write-Host "Kind: $($summary.kind) | SessionId: $($summary.sessionId)" -ForegroundColor Cyan
  Write-Host "Title: $($summary.customTitle) | Agent: $($summary.agentName)" -ForegroundColor Cyan
  Write-Host "Entrypoint: $($summary.entrypoint)" -ForegroundColor Cyan
  Write-Host "CWD: $($summary.cwd)" -ForegroundColor Cyan
  Write-Host ("Markers: channel={0} queue={1} bridge={2} sidechain={3}" -f `
      $summary.hasChannelMessage, `
      $summary.hasQueueOperation, `
      $summary.hasBridgeStatus, `
      $summary.hasSidechainMarker) -ForegroundColor Magenta
  Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor White -BackgroundColor Red
}

$createdSub = Register-ObjectEvent -InputObject $watcher -EventName Created -Action $handler

try {
  if ($RunSeconds -gt 0) {
    $endAt = (Get-Date).AddSeconds($RunSeconds)
    while ((Get-Date) -lt $endAt) {
      Wait-Event -Timeout 1 | Out-Null
    }
  } else {
    while ($true) {
      Wait-Event -Timeout 1 | Out-Null
    }
  }
}
finally {
  Unregister-Event -SourceIdentifier $createdSub.Name -ErrorAction SilentlyContinue
  $createdSub | Remove-Job -Force -ErrorAction SilentlyContinue
  $watcher.EnableRaisingEvents = $false
  $watcher.Dispose()
  Write-Host ""
  Write-Host "JSONL ALARM STOPPED" -ForegroundColor Yellow
}
