# Chocolatey engine: updates a single Package via `choco upgrade -y --no-progress`.
#
# Exit code conventions (Chocolatey docs):
#   0     = success (upgraded)
#   1641  = success, reboot initiated
#   3010  = success, reboot pending
#   2     = no upgrade available (treat as AlreadyLatest, not Failed)
#   1605  = package not installed (NotInstalled)

function Update-ChocoPackage {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Package,
        [switch]$WhatIf
    )

    $id = $Package.Id
    if (-not $id) {
        return @{ State = 'Failed'; Reason = "choco: Id is empty for '$($Package.Name)'." }
    }

    if (-not $WhatIf) {
        try {
            $listOut = & choco list $id --local-only --no-progress 2>$null
            if (-not ($listOut | Where-Object { $_ -match "^\s*$([regex]::Escape($id))\s" })) {
                return @{ State = 'NotInstalled'; Reason = "choco list $id returned no row." }
            }
        } catch {
            Write-Verbose "Update-ChocoPackage: presence probe failed: $($_.Exception.Message)"
        }
    }

    $upgradeArgs = @('upgrade', $id, '-y', '--no-progress')

    if ($WhatIf) {
        Write-UpdateStatus "  [WhatIf] choco $($upgradeArgs -join ' ')"
        return @{ State = 'Updated'; Reason = '(WhatIf)' }
    }

    Write-UpdateStatus "Updating $($Package.Name) (choco $id)..."
    Write-Verbose "  choco $($upgradeArgs -join ' ')"
    $out = & choco @upgradeArgs *>&1
    $exit = $LASTEXITCODE
    $joined = ($out | ForEach-Object { $_.ToString() }) -join "`n"
    if ($joined) { Write-Verbose $joined }
    if ($exit -eq 0) {
        return @{ State = 'Updated'; Reason = $null }
    }
    if ($exit -in @(1641, 3010)) {
        return @{ State = 'Updated'; Reason = "Reboot pending (choco exit $exit)." }
    }
    if ($exit -eq 2) {
        return @{ State = 'AlreadyLatest'; Reason = 'choco reports no upgrade available (exit 2).' }
    }
    if ($exit -eq 1605) {
        return @{ State = 'NotInstalled'; Reason = 'choco reports package not installed (exit 1605).' }
    }
    return @{ State = 'Failed'; Reason = "choco upgrade $id exited with $exit.$(Get-CapturedOutputTail $joined)" }
}
