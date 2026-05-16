# npmGlobal engine: uninstalls a single package via `npm uninstall -g`.

function Uninstall-NpmGlobalPackage {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Package,
        [switch]$WhatIf
    )

    $id = $Package.Id
    if (-not $id) {
        return @{ State = 'Failed'; Reason = "npmGlobal: Id is empty for '$($Package.Name)'." }
    }

    if (-not (Get-Command npm -ErrorAction SilentlyContinue) -and
        -not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
        return @{ State = 'Failed'; Reason = "npm not on PATH." }
    }

    if (-not $WhatIf) {
        try {
            $listOut = & npm.cmd list -g --depth=0 2>$null | Out-String
            if ($listOut -notmatch "(?im)^\S+\s+$([regex]::Escape($id))@") {
                return @{ State = 'NotInstalled'; Reason = "npm list -g does not list $id." }
            }
        } catch {
            Write-Verbose "Uninstall-NpmGlobalPackage: presence probe failed: $($_.Exception.Message)"
        }
    }

    $uninstallArgs = @('uninstall', '-g', $id)

    if ($WhatIf) {
        Write-Host "  [WhatIf] npm $($uninstallArgs -join ' ')"
        return @{ State = 'Uninstalled'; Reason = '(WhatIf)' }
    }

    Write-Host "  npm $($uninstallArgs -join ' ')"
    & npm.cmd @uninstallArgs
    $exit = $LASTEXITCODE
    if ($exit -eq 0) {
        return @{ State = 'Uninstalled'; Reason = $null }
    }
    return @{ State = 'Failed'; Reason = "npm uninstall -g $id exited with $exit." }
}
