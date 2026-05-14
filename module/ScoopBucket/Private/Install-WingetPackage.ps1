# Winget engine: installs a single Package via `winget install`.
#
# Inputs:
#   - $Package  : [Package] instance with Installer='winget'.
#   - $WhatIf   : when $true, only logs the command that would run.
#
# Behaviour:
#   - Source='msstore'  => `winget install --source msstore --id <Id>
#                            --accept-package-agreements --accept-source-agreements`
#   - Source=''         => `winget install --id <Id> --scope machine`
#                          (or --scope user when Package.Scope='user')
#   - Skips when AlreadyInstalled (winget list --id <Id> exit 0).
#   - Returns a hashtable @{ State='Installed'|'AlreadyInstalled'|'Failed'; Reason=<string> }.

function Install-WingetPackage {
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

    # AlreadyInstalled probe: `winget list --id <id>` exits 0 when found.
    if (-not $WhatIf) {
        try {
            $listArgs = @('list', '--id', $id, '--accept-source-agreements')
            if ($Package.Source -eq 'msstore') {
                $listArgs += @('--source', 'msstore')
            }
            $null = & winget @listArgs 2>$null
            if ($LASTEXITCODE -eq 0) {
                return @{ State = 'AlreadyInstalled'; Reason = "winget list --id $id returned 0." }
            }
        } catch {
            Write-Verbose "Install-WingetPackage: AlreadyInstalled probe failed: $($_.Exception.Message)"
        }
    }

    $installArgs = @('install', '--id', $id, '--accept-package-agreements', '--accept-source-agreements')
    if ($Package.Source -eq 'msstore') {
        $installArgs += @('--source', 'msstore')
    } else {
        $scope = if ($Package.Scope -eq 'user') { 'user' } else { 'machine' }
        $installArgs += @('--scope', $scope)
    }

    if ($WhatIf) {
        Write-Host "  [WhatIf] winget $($installArgs -join ' ')"
        return @{ State = 'Installed'; Reason = '(WhatIf)' }
    }

    Write-Host "  winget $($installArgs -join ' ')"
    & winget @installArgs
    $exit = $LASTEXITCODE
    # winget returns 0 on success; non-zero on failure. -1978335189 is
    # "already installed" in some versions — treat as success.
    if ($exit -eq 0) {
        return @{ State = 'Installed'; Reason = $null }
    }
    if ($exit -eq -1978335189) {
        return @{ State = 'AlreadyInstalled'; Reason = "winget reported already installed (exit $exit)." }
    }
    return @{ State = 'Failed'; Reason = "winget install --id $id exited with $exit." }
}
