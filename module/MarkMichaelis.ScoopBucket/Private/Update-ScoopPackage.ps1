# Scoop engine: updates a single Package via `scoop update <app>`.
#
# Scoop's update command takes the bare app name (no bucket prefix), so
# we strip the '<bucket>/' segment from Package.Id before dispatch — the
# exact same parsing Install/Uninstall-ScoopPackage use.

function Update-ScoopPackage {
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
            Write-Verbose "Update-ScoopPackage: presence probe failed: $($_.Exception.Message)"
        }
    }

    $updateArgs = @('update', $appName)

    if ($WhatIf) {
        Write-Host "  [WhatIf] scoop $($updateArgs -join ' ')"
        return @{ State = 'Updated'; Reason = '(WhatIf)' }
    }

    Write-Host "  scoop $($updateArgs -join ' ')"
    # Capture all streams (stdout 1, stderr 2, information 6). Scoop's
    # internal scoop.ps1 writes its per-app status via Write-Host which
    # in PS7 lands on the Information stream, not stdout — without `6>&1`
    # we'd miss the "(latest version)" / "is already installed" markers
    # we rely on to distinguish Updated from AlreadyLatest.
    $out = & scoop @updateArgs *>&1
    $exit = $LASTEXITCODE
    $joined = ($out | ForEach-Object { $_.ToString() }) -join "`n"
    # Surface scoop's own output for visibility (it prints per-app status
    # lines like "'jq' is already installed.").
    if ($joined) { Write-Host $joined }
    if ($exit -eq 0) {
        # Scoop returns 0 even when the app is already at the latest
        # version; the only signal that distinguishes "did work" from
        # "no work" is the textual "latest version" / "already installed"
        # marker in its output. Surface that as AlreadyLatest.
        if ($joined -match '(?im)latest version|is already installed') {
            return @{ State = 'AlreadyLatest'; Reason = 'scoop reported already at latest version.' }
        }
        return @{ State = 'Updated'; Reason = $null }
    }
    return @{ State = 'Failed'; Reason = "scoop update $appName exited with $exit." }
}
