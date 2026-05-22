param(
  [int]$CooldownMinutes = 30,
  [int]$MaxRuntimeSeconds = 120,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Write-Log {
  param([string]$Message)
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$ts] $Message"
}

$homeDir = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($homeDir)) {
  throw "USERPROFILE not set."
}

$stateDir = Join-Path $homeDir ".claude\episodic-memory-safe"
$stateFile = Join-Path $stateDir "state.json"
$lockFile = Join-Path $stateDir "sync.lock"
$pluginRoot = Join-Path $homeDir ".claude\plugins\cache\superpowers-marketplace\episodic-memory\1.0.15"
$syncJs = Join-Path $pluginRoot "dist\sync.js"
$pathsJs = Join-Path $pluginRoot "dist\paths.js"
$nodeExe = "C:\Program Files\nodejs\node.exe"

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

if (-not (Test-Path -LiteralPath $syncJs)) {
  throw "sync.js not found: $syncJs"
}
if (-not (Test-Path -LiteralPath $pathsJs)) {
  throw "paths.js not found: $pathsJs"
}

if (-not (Test-Path -LiteralPath $nodeExe)) {
  throw "node.exe not found: $nodeExe"
}

# Simple single-run lock to avoid parallel hook storms.
if (Test-Path -LiteralPath $lockFile) {
  Write-Log "Skip: lock file exists ($lockFile)."
  exit 0
}

$null = New-Item -ItemType File -Path $lockFile -Force
try {
  $nowUtc = (Get-Date).ToUniversalTime()
  $lastRunUtc = $null
  if (Test-Path -LiteralPath $stateFile) {
    try {
      $state = $null
      $rawState = Get-Content -LiteralPath $stateFile -Raw
      $rawState = $rawState.Trim([char]0xFEFF)
      if (-not [string]::IsNullOrWhiteSpace($rawState)) {
        $state = $rawState | ConvertFrom-Json
      } else {
        $state = $null
      }
      if ($state.lastRunUtc) {
        if ($state.lastRunUtc -is [datetime]) {
          $lastRunUtc = ([datetime]$state.lastRunUtc).ToUniversalTime()
        } else {
          $lastRunUtc = [datetimeoffset]::Parse(
            [string]$state.lastRunUtc,
            [System.Globalization.CultureInfo]::InvariantCulture
          ).UtcDateTime
        }
      }
    } catch {
      Write-Log ("State parse failed ({0}), continuing with empty state." -f $_.Exception.Message)
    }
  }

  if ($lastRunUtc) {
    $elapsed = $nowUtc - $lastRunUtc
    if ($elapsed.TotalMinutes -lt $CooldownMinutes) {
      Write-Log ("Skip: cooldown active ({0:n1}/{1} min)." -f $elapsed.TotalMinutes, $CooldownMinutes)
      exit 0
    }
  }

  # Skip if sync already running from another trigger.
  $alreadyRunning = @(Get-CimInstance Win32_Process |
      Where-Object {
        $_.Name -eq "node.exe" -and
        $_.CommandLine -match "episodic-memory\\1\.0\.15\\dist\\sync\.js"
      })
  if ($alreadyRunning.Count -gt 0) {
    Write-Log "Skip: sync-cli already running."
    exit 0
  }

  $newState = @{
    lastRunUtc = $nowUtc.ToString("o")
  } | ConvertTo-Json -Depth 3
  Set-Content -LiteralPath $stateFile -Value $newState -Encoding UTF8

  if ($DryRun) {
    Write-Log "DryRun: would execute safe sync now."
    exit 0
  }

  Write-Log "Starting episodic-memory sync (safe mode, skip summaries)."
  $syncCode = @"
import os from 'os';
import path from 'path';
import { syncConversations } from '$($syncJs.Replace('\','/'))';
import { getArchiveDir } from '$($pathsJs.Replace('\','/'))';

const sourceDir = path.join(os.homedir(), '.claude', 'projects');
const destDir = getArchiveDir();
await syncConversations(sourceDir, destDir, { skipSummaries: true });
"@

  $proc = Start-Process -FilePath $nodeExe -ArgumentList @("--input-type=module", "--eval", $syncCode) -PassThru -WindowStyle Hidden
  if (-not $proc.WaitForExit($MaxRuntimeSeconds * 1000)) {
    Write-Log "Timeout reached, stopping sync process tree."
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

    Get-CimInstance Win32_Process |
      Where-Object { $_.ParentProcessId -eq $proc.Id } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    exit 0
  }

  Write-Log "Sync finished."
  exit 0
}
finally {
  Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
}
