$ErrorActionPreference = "SilentlyContinue"

Write-Host "== STOP Claude + Episodic-Memory ==" -ForegroundColor Yellow

# 1) Alle Claude-Prozesse stoppen
Get-Process claude | Stop-Process -Force

# 2) Relevante node-Prozesse stoppen
Get-CimInstance Win32_Process |
  Where-Object {
    $_.Name -eq 'node.exe' -and
    $_.CommandLine -match 'episodic-memory|sync-cli|claude-agent-sdk|mcp-server-wrapper|mcp-server\.js'
  } |
  ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force
  }

Start-Sleep -Seconds 1

Write-Host "== VERIFY (sollte leer sein) ==" -ForegroundColor Cyan

Get-CimInstance Win32_Process |
  Where-Object {
    $_.Name -match 'claude|node' -and
    $_.CommandLine -match 'episodic-memory|sync-cli|claude-agent-sdk|mcp-server-wrapper|mcp-server\.js|CC-SessionCoord'
  } |
  Select-Object ProcessId, Name, CommandLine

