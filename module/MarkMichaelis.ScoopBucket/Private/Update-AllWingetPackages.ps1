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
    $out = & winget @upgradeArgs *>&1
    $exit = $LASTEXITCODE
    $joined = ($out | ForEach-Object { $_.ToString() }) -join "`n"
    if ($joined) { Write-Verbose $joined }
    if ($exit -eq 0) {
        return @{ State = 'Updated'; Reason = $null; Engine = 'winget' }
    }
    return @{ State = 'Failed'; Reason = "winget upgrade --all exited with $exit.$(Get-CapturedOutputTail $joined)"; Engine = 'winget' }
}
