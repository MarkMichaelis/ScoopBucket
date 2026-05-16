# Winget engine: uninstalls a single Package via `winget uninstall`.
#
# Inverse of Install-WingetPackage. The presence probe is identical
# (`winget list --id <Id>`) but inverted: exit 0 ⇒ installed ⇒ uninstall;
# non-zero ⇒ NotInstalled short-circuit.

function Uninstall-WingetPackage {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Package,
        [switch]$WhatIf
    )

    $id = $Package.Id
    if (-not $id) {
        return @{ State = 'Failed'; Reason = "winget: Id is empty for '$($Package.Name)'." }
    }

    if (-not $WhatIf) {
        try {
            $listArgs = @('list', '--id', $id, '--accept-source-agreements')
            if ($Package.Source -eq 'msstore') {
                $listArgs += @('--source', 'msstore')
            }
            $null = & winget @listArgs 2>$null
            if ($LASTEXITCODE -ne 0) {
                return @{ State = 'NotInstalled'; Reason = "winget list --id $id returned $LASTEXITCODE." }
            }
        } catch {
            Write-Verbose "Uninstall-WingetPackage: presence probe failed: $($_.Exception.Message)"
        }
    }

    $uninstallArgs = @('uninstall', '--id', $id, '--silent', '--accept-source-agreements')
    if ($Package.Scope -in @('machine','global')) {
        $uninstallArgs += @('--scope', 'machine')
    }

    if ($WhatIf) {
        Write-Host "  [WhatIf] winget $($uninstallArgs -join ' ')"
        return @{ State = 'Uninstalled'; Reason = '(WhatIf)' }
    }

    Write-Host "  winget $($uninstallArgs -join ' ')"
    & winget @uninstallArgs
    $exit = $LASTEXITCODE
    if ($exit -eq 0) {
        return @{ State = 'Uninstalled'; Reason = $null }
    }
    return @{ State = 'Failed'; Reason = "winget uninstall --id $id exited with $exit." }
}
