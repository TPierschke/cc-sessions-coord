# Publish scrubbed HEAD to public cc-sessions-coord (single-commit history).
# Dev repo must be cc-sessions-coord-dev on GitHub; run from dev clone.
param(
  [string]$DevRoot = (Split-Path $PSScriptRoot -Parent),
  [string]$ExportRoot = (Join-Path (Split-Path $DevRoot -Parent) 'cc-sessions-coord-public-export'),
  [string]$PublicRemote = 'https://github.com/TPierschke/cc-sessions-coord.git',
  [string]$Tag = 'v0.3.11-public'
)
$ErrorActionPreference = 'Stop'
$zip = Join-Path $env:TEMP 'ccsc-public-archive.zip'
Remove-Item -Recurse -Force $ExportRoot, $zip -ErrorAction SilentlyContinue
git -C $DevRoot archive -o $zip HEAD
Expand-Archive -Path $zip -DestinationPath $ExportRoot -Force
Remove-Item $zip -Force
Remove-Item -Recurse -Force (Join-Path $ExportRoot '.cursor-notes') -ErrorAction SilentlyContinue
Push-Location $ExportRoot
if (-not (Test-Path .git)) { git init -b main } else { git checkout -B main 2>$null }
git add -A
$msg = "Public release $Tag (tree from dev $(git -C $DevRoot rev-parse --short HEAD))"
git diff --cached --quiet
if ($LASTEXITCODE -ne 0) { git commit -m $msg } else { Write-Host "No file changes since last export." }
if (-not (git remote get-url origin 2>$null)) { git remote add origin $PublicRemote }
git push -u origin main --force
git tag -f $Tag
git push -f origin $Tag
Pop-Location
Write-Host "OK: pushed to $PublicRemote (tag $Tag)"
