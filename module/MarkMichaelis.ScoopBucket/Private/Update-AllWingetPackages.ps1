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
    # does per package (#547). Only packages winget lists as upgradable are
    # touched, so a program with nothing to upgrade is never disturbed. Exit 0
    # does not prove each of them was upgraded (--all skips pinned packages);
    # Complete-InUseFileAside judges that per package folder.
    $index = Get-PackageUpdateIndex -Installers 'winget'
    $wingetMap = if ($index -and $index['winget']) { $index['winget'] } else { @{} }
    if ($wingetMap.Count -eq 0) {
        Write-Verbose 'Update-AllWingetPackages: no winget upgrade index (winget list failed or listed nothing); running programs are not set aside this sweep.'
    }
    $upgradable = @($wingetMap.Keys | Where-Object {
            $entry = $wingetMap[$_]
            $entry.Available -and $entry.Available -ne $entry.Installed
        })
    $aside = @(Move-InUseFileAside -Directory @($upgradable | ForEach-Object { Get-WingetPortableDirectory -Id $_ }))
    $exit = $null
    try {
        $out = & winget @upgradeArgs *>&1
        $exit = $LASTEXITCODE
    } finally {
        $settled = Complete-InUseFileAside -Moved $aside -Upgraded:($exit -eq 0)
    }
    $joined = ($out | ForEach-Object { $_.ToString() }) -join "`n"
    if ($joined) { Write-Verbose $joined }
    if ($exit -eq 0) {
        $note = if ($settled.Moved -gt $settled.Restored) { Get-InUseUpgradeNote -Count ($settled.Moved - $settled.Restored) }
        return @{ State = 'Updated'; Reason = $note; Engine = 'winget' }
    }
    return @{ State = 'Failed'; Reason = "winget upgrade --all exited with $exit.$(Get-CapturedOutputTail $joined)"; Engine = 'winget' }
}
