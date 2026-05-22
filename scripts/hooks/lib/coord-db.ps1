# -----------------------------------------------------------------------------
# coord-db.ps1 — shared psql helpers for the hooks.
# All hook DB connections use the ccsc_hook role (low privilege).
# -----------------------------------------------------------------------------

$script:CCSC_PSQL  = $env:CCSC_PSQL
if (-not $script:CCSC_PSQL) { $script:CCSC_PSQL = 'psql' }

$script:CCSC_HOST  = if ($env:CCSC_PG_HOST) { $env:CCSC_PG_HOST } else { 'localhost' }
$script:CCSC_PORT  = if ($env:CCSC_PG_PORT) { $env:CCSC_PG_PORT } else { '5432' }
$script:CCSC_DB    = if ($env:CCSC_PG_DB)   { $env:CCSC_PG_DB }   else { 'cc_sessions_coord' }
$script:CCSC_USER  = if ($env:CCSC_HOOK_USER) { $env:CCSC_HOOK_USER } else { 'ccsc_hook' }
$script:CCSC_PASS  = $env:CCSC_HOOK_PW
if (-not $script:CCSC_PASS) { throw 'CCSC_HOOK_PW must be set for coord hooks.' }
$script:CCSC_TIMEOUT_MS = if ($env:CCSC_HOOK_TIMEOUT_MS) { [int]$env:CCSC_HOOK_TIMEOUT_MS } else { 80 }

function Invoke-CoordSql {
    param(
        [Parameter(Mandatory=$true)][string]$Sql,
        [int]$TimeoutMs = 0
    )
    if ($TimeoutMs -le 0) { $TimeoutMs = $script:CCSC_TIMEOUT_MS }
    $env:PGPASSWORD = $script:CCSC_PASS
    $env:PGOPTIONS  = "--statement-timeout=$TimeoutMs"
    & $script:CCSC_PSQL `
        -h $script:CCSC_HOST -p $script:CCSC_PORT -U $script:CCSC_USER -d $script:CCSC_DB `
        -t -A -F '|' -X -q -c $Sql 2>$null
}

function Get-MySessionShortId {
    # Find own short_id by claude_pid (walk up to claude.exe).
    # We pass claude_pid as env from cc-yolo? -- no, simpler: pick the active session whose
    # bridge_pid matches one of our ancestors. Fallback: pick most recently started 'active'.
    # For now: deterministic via env override (CCSC_SHORT_ID), else newest active.
    if ($env:CCSC_SHORT_ID) { return $env:CCSC_SHORT_ID }
    $row = Invoke-CoordSql "SELECT short_id FROM coord.sessions WHERE status='active' ORDER BY started_at DESC LIMIT 1;"
    if ($row) { return ($row | Select-Object -First 1).Trim() }
    return $null
}
