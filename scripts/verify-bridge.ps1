# Channel bridge regression guard — run after any change under ChannelBridge/
#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$bridge = Join-Path $repo 'src/CcSessionsCoord.ChannelBridge'

Push-Location $bridge
try {
    npm run build
    if ($LASTEXITCODE -ne 0) { throw "npm run build failed" }
    npm run verify
    if ($LASTEXITCODE -ne 0) { throw "npm run verify failed" }
    Write-Host 'verify-bridge: PASS' -ForegroundColor Green
} finally {
    Pop-Location
}
