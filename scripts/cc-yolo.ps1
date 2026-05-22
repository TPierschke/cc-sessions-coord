# -----------------------------------------------------------------------------
# cc-yolo.ps1 -- Wrapper for Claude Code sessions with coord integration.
#
# Calls:
#   cc-yolo MeinName               # new session
#   cc-yolo Mein Name mit Spaces   # same, multi-word
#   cc-yolo                        # interactive prompt for name (new session)
#   cc-yolo -r                     # claude's resume picker
#   cc-yolo -r <search>            # resume picker pre-filtered with claude's -r value
#   cc-yolo -c                     # continue most recent conversation in cwd
#
# Only the new-session paths pass --name <name> and set $env:CCSC_SESSION_NAME.
# Resume (-r) and Continue (-c) never touch the display name -- claude keeps the
# name it already has in the JSONL / DB.
# -----------------------------------------------------------------------------
[CmdletBinding()]
param(
    [switch]$Resume,
    [switch]$Continue,
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$NameOrArgs
)

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: claude CLI not found in PATH" -ForegroundColor Red
    exit 1
}

# PowerShell only binds single-dash params. Claude-style long flags (--resume, --continue)
# would otherwise land in $NameOrArgs as positional args and end up parsed as session names.
# Pull them out here and set the corresponding switch.
$stripped = @()
foreach ($a in $NameOrArgs) {
    if ($a -ieq '--resume')   { $Resume   = $true; continue }
    if ($a -ieq '--continue') { $Continue = $true; continue }
    $stripped += $a
}
$NameOrArgs = $stripped

# Channels flag enables the ccsc-channel MCP server to push notifications/claude/channel into the session.
$script:ClaudeBaseArgs = @('--dangerously-skip-permissions', '--dangerously-load-development-channels', 'server:ccsc-channel')

# Echo the final command before invoking claude. Callers decide whether --name is in $ExtraArgs.
function Invoke-Claude {
    param([string[]]$ExtraArgs)
    $allArgs = $script:ClaudeBaseArgs + $ExtraArgs

    $echoParts = @()
    if ($env:CCSC_SESSION_NAME) {
        $echoParts += "`$env:CCSC_SESSION_NAME='$($env:CCSC_SESSION_NAME)';"
    }
    $echoParts += 'claude'
    foreach ($a in $allArgs) {
        if ($a -match '\s') { $echoParts += "'$a'" } else { $echoParts += $a }
    }
    Write-Host ('[cc-yolo] ' + ($echoParts -join ' ')) -ForegroundColor Cyan
    & claude @allArgs
}

try {
    $ver = & claude --version 2>$null
    Write-Host "claude $ver" -ForegroundColor DarkGray
} catch {
    Write-Host "WARN: 'claude --version' fehlgeschlagen -- wird trotzdem versucht" -ForegroundColor Yellow
}

# --- Continue path: -c, no --name, no env touching.
if ($Continue) {
    Invoke-Claude -ExtraArgs @('--continue')
    return
}

# --- Resume path: -r <search>, no --name, no env touching.
# Picker without search-term is forbidden: cc-yolo would not know which session
# claude actually loads (the user picks interactively after claude starts), so coord
# tracking and a stale $env:CCSC_SESSION_NAME would silently attach to the wrong session.
# Force the user to be explicit so we always know what is loaded.
if ($Resume) {
    if (-not ($NameOrArgs -and $NameOrArgs.Count -gt 0)) {
        Write-Host "ERROR: 'cc-yolo -r' braucht einen Namen/Search-Term." -ForegroundColor Red
        Write-Host "Beispiel: cc-yolo -r T3" -ForegroundColor DarkGray
        Write-Host "Picker ohne Argument geht ueber: claude --resume (direkt, ohne cc-yolo)." -ForegroundColor DarkGray
        exit 1
    }
    $search = ($NameOrArgs -join ' ').Trim()
    $env:CCSC_SESSION_NAME = $search
    Write-Host "Resume (search): $search" -ForegroundColor Cyan
    Invoke-Claude -ExtraArgs @('--resume', $search)
    return
}

# --- New-session path: --name <name>, sets $env:CCSC_SESSION_NAME for the bridge.
$name = ""
if ($NameOrArgs -and $NameOrArgs.Count -gt 0) {
    $name = ($NameOrArgs -join ' ').Trim()
}
if (-not $name) {
    $name = (Read-Host "Session-Name").Trim()
}
if (-not $name) {
    Write-Host "ERROR: Session-Name darf nicht leer sein" -ForegroundColor Red
    exit 1
}

$env:CCSC_SESSION_NAME = $name
Write-Host "Starte Sitzung: $name" -ForegroundColor Green
Invoke-Claude -ExtraArgs @('--name', $name)
