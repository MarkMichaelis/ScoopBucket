# Chocolatey engine: uninstalls a single Package via `choco uninstall -y`.

function Uninstall-ChocoPackage {
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
            Write-Verbose "Uninstall-ChocoPackage: presence probe failed: $($_.Exception.Message)"
        }
    }

    $uninstallArgs = @('uninstall', $id, '-y')

    if ($WhatIf) {
        Write-Host "  [WhatIf] choco $($uninstallArgs -join ' ')"
        return @{ State = 'Uninstalled'; Reason = '(WhatIf)' }
    }

    Write-Host "  choco $($uninstallArgs -join ' ')"
    & choco @uninstallArgs
    $exit = $LASTEXITCODE
    # 0 = success; 1605 = not installed; 1641/3010 = reboot pending.
    if ($exit -eq 0 -or $exit -in @(1641, 3010)) {
        return @{ State = 'Uninstalled'; Reason = if ($exit -ne 0) { "Reboot pending (choco exit $exit)." } else { $null } }
    }
    if ($exit -eq 1605) {
        return @{ State = 'NotInstalled'; Reason = "choco reported not installed (exit 1605)." }
    }
    return @{ State = 'Failed'; Reason = "choco uninstall $id -y exited with $exit." }
}
