# -----------------------------------------------------------------------------
# pre-tool-use.ps1 -- conflict-check hook (PreToolUse).
# Reads tool-call JSON from stdin. Blocks if another active session touched
# the same file via Edit/Write/MultiEdit in the last 30s.
# -----------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'

. "$PSScriptRoot\lib\coord-db.ps1"

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    exit 0
}

$toolName = $obj.tool_name
if ($toolName -notin @('Edit', 'Write', 'MultiEdit')) { exit 0 }
$filePath = $obj.tool_input.file_path
if (-not $filePath) { exit 0 }

$myShort = Get-MySessionShortId
if (-not $myShort) { exit 0 }

# Escape single quotes for SQL
$pE = $filePath -replace "'", "''"
$sE = $myShort -replace "'", "''"
$tE = $toolName -replace "'", "''"
$sql = "SELECT conflict_short || '|' || conflict_display FROM coord.ccsc_check_conflict('$sE', '$tE', '$pE');"

try {
    $out = Invoke-CoordSql -Sql $sql -TimeoutMs $script:CCSC_TIMEOUT_MS
} catch {
    exit 0 # fail-open
}

if ($out) {
    $line = ($out | Select-Object -First 1).Trim()
    if ($line) {
        $parts = $line -split '\|', 2
        $cShort = $parts[0]
        $cDisplay = if ($parts.Length -ge 2) { $parts[1] } else { $cShort }
        $msg = "Konflikt: Sitzung '$cDisplay' ($cShort) hat $filePath in den letzten 30s editiert."
        $resp = @{ decision = 'block'; reason = $msg } | ConvertTo-Json -Compress
        Write-Output $resp
        exit 2
    }
}
exit 0
