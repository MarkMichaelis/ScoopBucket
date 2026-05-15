# Chocolatey engine: installs a single Package via `choco install -y`.
#
# AlreadyInstalled probe parses `choco list <id> --local-only --no-progress`.
# Scope is meaningless for choco (it installs machine-wide); the Scope
# field on Package is ignored here.

function Install-ChocoPackage {
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
            if ($listOut | Where-Object { $_ -match "^\s*$([regex]::Escape($id))\s" }) {
                return @{ State = 'AlreadyInstalled'; Reason = "choco list $id returned a row." }
            }
        } catch {
            Write-Verbose "Install-ChocoPackage: AlreadyInstalled probe failed: $($_.Exception.Message)"
        }
    }

    $installArgs = @('install', '-y', $id)
    if ($WhatIf) {
        Write-Host "  [WhatIf] choco $($installArgs -join ' ')"
        return @{ State = 'Installed'; Reason = '(WhatIf)' }
    }

    Write-Host "  choco $($installArgs -join ' ')"
    & choco @installArgs
    $exit = $LASTEXITCODE
    # 0 = success; 1641 / 3010 = reboot pending; 1605 = not installed
    # (uninstall path). Treat 0/1641/3010 as success.
    if ($exit -in @(0, 1641, 3010)) {
        return @{ State = 'Installed'; Reason = if ($exit -ne 0) { "Reboot pending (choco exit $exit)." } else { $null } }
    }
    return @{ State = 'Failed'; Reason = "choco install -y $id exited with $exit." }
}
