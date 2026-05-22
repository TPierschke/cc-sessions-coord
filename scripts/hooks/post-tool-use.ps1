# -----------------------------------------------------------------------------
# post-tool-use.ps1 -- writes a row into coord.activities for every Edit/Write
# call. Runs async so it never blocks the tool.
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

$pE = $filePath -replace "'", "''"
$sE = $myShort -replace "'", "''"
$tE = $toolName -replace "'", "''"
$sql = "INSERT INTO coord.activities(short_id, tool, path) VALUES ('$sE', '$tE', '$pE');"

# Fire-and-forget (don't wait for completion).
$psqlPath = $script:CCSC_PSQL
$pgArgs = @(
    '-h', $script:CCSC_HOST,
    '-p', $script:CCSC_PORT,
    '-U', $script:CCSC_USER,
    '-d', $script:CCSC_DB,
    '-X', '-q', '-c', $sql
)
$env:PGPASSWORD = $script:CCSC_PASS
Start-Process -FilePath $psqlPath -ArgumentList $pgArgs -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
exit 0
