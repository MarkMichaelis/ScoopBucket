# Winget engine: updates a single Package via `winget upgrade`.
#
# Mirrors Install-WingetPackage. Behaviour:
#   - Presence probe (`winget list --id <Id>`); exit non-zero ⇒ NotInstalled.
#   - `winget upgrade --id <Id> --silent --accept-package-agreements --accept-source-agreements`
#     plus --scope mapping (global/machine→machine, user→user) and any
#     WingetExtraArgs the bundle declared.
#   - Exit code -1978335212 (NO_APPLICABLE_UPGRADE) AND -1978335189
#     (already-installed sentinel) map to State='AlreadyLatest'.
#   - Source='msstore' uses --source msstore (no --scope).

function Update-WingetPackage {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Package,
        [switch]$WhatIf,
        # Per-call hard cap on winget runtime. Set to 0 to disable (the
        # legacy behavior). Default 15 minutes matches Invoke-WithTimeout
        # in .github/scripts/Test-Installs.ps1 and is enough headroom for
        # large MSI installers without leaving a Squirrel-style hang
        # blocking the rest of the sweep. See #269.
        [int]$TimeoutMinutes = 15
    )

    $id = $Package.Id
    if (-not $id) {
        return @{ State = 'Failed'; Reason = "winget: Id is empty for '$($Package.Name)'." }
    }

    if (-not $WhatIf) {
        try {
            $listArgs = @('list', '--id', $id, '--accept-source-agreements')
            if ($Package.Source -eq 'msstore') { $listArgs += @('--source', 'msstore') }
            $null = & winget @listArgs 2>$null
            if ($LASTEXITCODE -ne 0) {
                return @{ State = 'NotInstalled'; Reason = "winget list --id $id returned $LASTEXITCODE." }
            }
        } catch {
            Write-Verbose "Update-WingetPackage: presence probe failed: $($_.Exception.Message)"
        }
    }

    $upgradeArgs = @('upgrade', '--id', $id, '--silent', '--accept-package-agreements', '--accept-source-agreements')
    if ($Package.Source -eq 'msstore') {
        $upgradeArgs += @('--source', 'msstore')
    } else {
        $scope = if ($Package.Scope -eq 'user') { 'user' } else { 'machine' }
        $upgradeArgs += @('--scope', $scope)
    }
    if ($Package.WingetExtraArgs -and $Package.WingetExtraArgs.Count -gt 0) {
        $upgradeArgs += @($Package.WingetExtraArgs)
    }

    if ($WhatIf) {
        Write-Host "  [WhatIf] winget $($upgradeArgs -join ' ')"
        return @{ State = 'Updated'; Reason = '(WhatIf)' }
    }

    Write-Host "  winget $($upgradeArgs -join ' ')"
    if ($TimeoutMinutes -gt 0) {
        $r = Invoke-WingetWithTimeout -Arguments $upgradeArgs -TimeoutSeconds ($TimeoutMinutes * 60)
        if ($r.TimedOut) {
            return @{ State = 'Failed'; Reason = "winget upgrade --id $id timed out after $TimeoutMinutes minute(s) and was killed (see #269)." }
        }
        $exit = $r.ExitCode
    } else {
        & winget @upgradeArgs
        $exit = $LASTEXITCODE
    }
    if ($exit -eq 0) {
        return @{ State = 'Updated'; Reason = $null }
    }
    # APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE (-1978335212) — "no
    # applicable upgrade found": the installed version is already the
    # latest the configured source advertises. Treat as a successful
    # no-op, not Failed.
    if ($exit -eq -1978335212 -or $exit -eq -1978335189) {
        return @{ State = 'AlreadyLatest'; Reason = "winget reports no applicable upgrade (exit $exit)." }
    }
    return @{ State = 'Failed'; Reason = "winget upgrade --id $id exited with $exit." }
}
