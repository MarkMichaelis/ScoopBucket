# winget bulk sweep: `winget upgrade --all` with the recommended noninteractive
# flags. Probes for `winget` first so a non-winget machine returns Skipped
# instead of throwing CommandNotFound.

function Update-AllWingetPackages {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([switch]$WhatIf)

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        return @{ State = 'Skipped'; Reason = 'winget not on PATH.'; Engine = 'winget' }
    }

    $upgradeArgs = @(
        'upgrade', '--all', '--include-unknown', '--silent',
        '--accept-package-agreements', '--accept-source-agreements'
    )

    if ($WhatIf) {
        Write-UpdateStatus "  [WhatIf] winget $($upgradeArgs -join ' ')"
        return @{ State = 'Updated'; Reason = '(WhatIf)'; Engine = 'winget' }
    }

    Write-UpdateStatus "Sweeping winget (winget upgrade --all)..."
    Write-Verbose "  winget $($upgradeArgs -join ' ')"
    # Running portable programs would fail their upgrade (and lose their command
    # alias); set their locked executables aside first, as Update-WingetPackage
    # does per package (#547).
    $aside = @(Move-InUseFileAside -Directory @(Get-WingetPortableDirectory))
    try {
        $out = & winget @upgradeArgs *>&1
        $exit = $LASTEXITCODE
    } finally {
        $settled = Complete-InUseFileAside -Moved $aside
    }
    $joined = ($out | ForEach-Object { $_.ToString() }) -join "`n"
    if ($joined) { Write-Verbose $joined }
    if ($exit -eq 0) {
        $note = if ($settled.Moved -gt $settled.Restored) { Get-InUseUpgradeNote -Count ($settled.Moved - $settled.Restored) }
        return @{ State = 'Updated'; Reason = $note; Engine = 'winget' }
    }
    return @{ State = 'Failed'; Reason = "winget upgrade --all exited with $exit.$(Get-CapturedOutputTail $joined)"; Engine = 'winget' }
}
