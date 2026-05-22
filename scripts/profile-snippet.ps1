# -----------------------------------------------------------------------------
# cc-sessions-coord PowerShell profile snippet.
#
# Dot-source this from your $PROFILE (CurrentUserAllHosts or similar):
#   . "$env:USERPROFILE\source\repos\TPierschke\cc-sessions-coord\scripts\profile-snippet.ps1"
#
# Provides the `cc-yolo` function as a thin wrapper around
# <repo>/scripts/cc-yolo.ps1, so updates to the wrapper script ship via
# git pull and never drift from the user profile.
# -----------------------------------------------------------------------------

$script:CcSessionsCoordScripts = Split-Path -Parent $PSCommandPath
$script:CcYoloWrapper          = Join-Path $script:CcSessionsCoordScripts 'cc-yolo.ps1'

function cc-yolo {
    & $script:CcYoloWrapper @args
}
