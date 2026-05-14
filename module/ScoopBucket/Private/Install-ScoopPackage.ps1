# Scoop engine: installs a single Package via `scoop install`.
#
# Scope mapping:
#   - 'global'  => scoop install -g <Id>     (machine-wide; requires admin)
#   - 'machine' => scoop install -g <Id>     (treated same as 'global' — Windows
#                  scoop has no "system" scope distinct from -g)
#   - 'user'    => scoop install <Id>        (per-user default)
#
# Special case: ids of the form 'MarkMichaelis/<App>' route through the
# bucket/Utils.ps1 Install-BucketApp helper when $env:SCOOPBUCKET_LOCAL_REPO
# points at the working-copy repo, so unpushed manifests under bucket/ can
# be exercised in CI without first being pushed to GitHub. When the env
# var is unset, falls through to the regular `scoop install <id>` path.

function Install-ScoopPackage {
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

    # Bucket-app routing (working-copy CI install): the bucket name is
    # the segment before the first '/'.
    $bucket, $appName = $id -split '/', 2
    if (-not $appName) { $appName = $bucket; $bucket = $null }

    if ($bucket -eq 'MarkMichaelis' -and $env:SCOOPBUCKET_LOCAL_REPO -and
        (Test-Path (Join-Path $env:SCOOPBUCKET_LOCAL_REPO "bucket\$appName.json"))) {
        if ($WhatIf) {
            Write-Host "  [WhatIf] Install-LocalManifest -ManifestName $appName"
            return @{ State = 'Installed'; Reason = '(WhatIf, local manifest)' }
        }
        # Install-LocalManifest is defined in bucket/Utils.ps1. When the
        # caller dot-sourced Utils first, the function is in scope. If
        # not, we fall back to the regular `scoop install` path below.
        $localFn = Get-Command 'Install-LocalManifest' -ErrorAction SilentlyContinue
        if ($localFn) {
            Write-Host "  Install-LocalManifest -ManifestName $appName"
            try {
                & $localFn -ManifestName $appName
                return @{ State = 'Installed'; Reason = $null }
            } catch {
                return @{ State = 'Failed'; Reason = "Install-LocalManifest $appName threw: $($_.Exception.Message)" }
            }
        }
    }

    # AlreadyInstalled probe: `scoop list <app>` lists the named app
    # only when installed; resolved by stripping any bucket prefix.
    if (-not $WhatIf) {
        try {
            $listOut = & scoop list $appName 2>$null | Out-String
            if ($listOut -match "(?im)^\s*$([regex]::Escape($appName))\s+\S+") {
                return @{ State = 'AlreadyInstalled'; Reason = "scoop list $appName returned a row." }
            }
        } catch {
            Write-Verbose "Install-ScoopPackage: AlreadyInstalled probe failed: $($_.Exception.Message)"
        }
    }

    $installArgs = @('install')
    if ($Package.Scope -ne 'user') { $installArgs += '-g' }
    $installArgs += $id

    if ($WhatIf) {
        Write-Host "  [WhatIf] scoop $($installArgs -join ' ')"
        return @{ State = 'Installed'; Reason = '(WhatIf)' }
    }

    Write-Host "  scoop $($installArgs -join ' ')"
    & scoop @installArgs
    $exit = $LASTEXITCODE
    if ($exit -eq 0) {
        return @{ State = 'Installed'; Reason = $null }
    }
    return @{ State = 'Failed'; Reason = "scoop install $id exited with $exit." }
}
