# One-time: rename local folder cc-sessions-coord -> cc-sessions-coord-dev (close Cursor/IDE first).
$parent = 'C:\Users\thomas.pierschke\source\repos\TPierschke'
$old = Join-Path $parent 'cc-sessions-coord'
$new = Join-Path $parent 'cc-sessions-coord-dev'
if (Test-Path $new) { Write-Host "Already renamed: $new"; exit 0 }
if (-not (Test-Path $old)) { throw "Not found: $old" }
Rename-Item -LiteralPath $old -NewName 'cc-sessions-coord-dev'
Write-Host "OK: $new — reopen workspace from this path."
