# Scoop engine: uninstalls a single Package via `scoop uninstall`.
#
# Scoop's uninstall command takes the bare app name (no bucket prefix),
# so we strip the '<bucket>/' segment from Package.Id before dispatch.

function Uninstall-ScoopPackage {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Package,
        [switch]$WhatIf
    )

    $id = $Package.Id
    if (-not $id) {
        return @{ State = 'Failed'; Reason = "scoop: Id is empty for '$($Package.Name)'." }
    }

    $bucket, $appName = $id -split '/', 2
    if (-not $appName) { $appName = $bucket }

    if (-not $WhatIf) {
        try {
            $listOut = & scoop list $appName 2>$null | Out-String
            if ($listOut -notmatch "(?im)^\s*$([regex]::Escape($appName))\s+\S+") {
                return @{ State = 'NotInstalled'; Reason = "scoop list $appName returned no row." }
            }
        } catch {
            Write-Verbose "Uninstall-ScoopPackage: presence probe failed: $($_.Exception.Message)"
        }
    }

    $uninstallArgs = @('uninstall', $appName)

    if ($WhatIf) {
        Write-Host "  [WhatIf] scoop $($uninstallArgs -join ' ')"
        return @{ State = 'Uninstalled'; Reason = '(WhatIf)' }
    }

    Write-Host "  scoop $($uninstallArgs -join ' ')"
    & scoop @uninstallArgs
    $exit = $LASTEXITCODE
    if ($exit -eq 0) {
        return @{ State = 'Uninstalled'; Reason = $null }
    }
    return @{ State = 'Failed'; Reason = "scoop uninstall $appName exited with $exit." }
}
