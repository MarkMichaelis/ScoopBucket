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
        # 'global' (the new default) and the legacy 'machine' value both
        # map to winget's --scope machine; only 'user' opts into per-user.
        $scope = if ($Package.Scope -eq 'user') { 'user' } else { 'machine' }
        $installArgs += @('--scope', $scope)
    }

    if ($WhatIf) {
        Write-Host "  [WhatIf] winget $($installArgs -join ' ')"
        return @{ State = 'Installed'; Reason = '(WhatIf)' }
    }

    # Retry transient installer failures up to 2 extra attempts. winget
    # surfaces several flake modes (network blip, installer ACCESS_VIOLATION
    # crash mid-MSI, "another install is in progress") with non-zero exit
    # codes that are NOT the "already installed" sentinel and NOT permanent
    # configuration errors. Retrying is cheap because AlreadyInstalled was
    # just probed; if the first attempt actually did install it, the next
    # invocation's own list probe will short-circuit. Failures stop being
    # retried once the exit code matches the user-scope-only / no-applicable-
    # installer permanent-error sentinels — retrying those is pure noise.
    $maxAttempts = 3
    $permanentFailureCodes = @(
        -1978335212  # APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER (user-scope only)
        -1978334969  # APPINSTALLER_CLI_ERROR_INSTALL_BLOCKED_BY_POLICY
    )
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            Write-Host "  winget install --id $id retry $($attempt - 1)/$($maxAttempts - 1) after exit $exit"
            Start-Sleep -Seconds 10
        }
        Write-Host "  winget $($installArgs -join ' ')"
        & winget @installArgs
        $exit = $LASTEXITCODE

        if ($exit -eq 0) {
            return @{ State = 'Installed'; Reason = $null }
        }
        if ($exit -eq -1978335189) {
            return @{ State = 'AlreadyInstalled'; Reason = "winget reported already installed (exit $exit)." }
        }
        if ($exit -in $permanentFailureCodes) {
            return @{ State = 'Failed'; Reason = "winget install --id $id exited with $exit (permanent; no retry)." }
        }
    }
    return @{ State = 'Failed'; Reason = "winget install --id $id exited with $exit after $maxAttempts attempts." }
}
