# Patches the NSSM service ACL so Authenticated Users may Start/Stop/Query/Pause
# the worker without elevation. Pattern verbatim from apply-update.ps1.
# Run once as Administrator. Idempotent.
$ServiceName = 'DT - cc-sessions-coord'

$currentSddl = (& sc.exe sdshow "$ServiceName" | Out-String).Trim()
Write-Host "Current SDDL: $currentSddl"

if ($currentSddl -match '\(A;;[A-Z]*?LCRPWP[A-Z]*?;;;AU\)') {
    Write-Host "ACL already patched - nothing to do" -ForegroundColor DarkGray
    pause
    return
}

$newAce = '(A;;LCRPWPDTRC;;;AU)'
if ($currentSddl -match '^(.*?D:)(.*?)((?:S:.*)?)$') {
    $prefix = $Matches[1]
    $dacl   = $Matches[2]
    $sacl   = $Matches[3]
    $newSddl = "$prefix$dacl$newAce$sacl"
    Write-Host "New SDDL: $newSddl"
    & sc.exe sdset "$ServiceName" "$newSddl"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "OK - Authenticated Users may now Start/Stop without admin" -ForegroundColor Green
    } else {
        Write-Host "FAILED - sc.exe sdset exit=$LASTEXITCODE" -ForegroundColor Red
    }
} else {
    Write-Host "Could not parse SDDL" -ForegroundColor Red
}
pause
