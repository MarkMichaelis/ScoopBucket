function Get-BundlePackages {
    <#
    .SYNOPSIS
        Internal: load every bucket/*.ps1 in a fresh runspace and capture
        the $Packages variable each bundle defines. Returns an array of
        PSCustomObjects with Bundle, BundlePath, and Packages members.
    .DESCRIPTION
        The cross-bundle loader for Install-Package / Get-Package.
        Migrated bundles use a sentinel — `$Packages = [Package[]]@(...)`
        followed by `Invoke-PackageInstall -Packages $Packages -Bundle …`
        — and we capture `$Packages` after the bundle assigns it but
        before `Invoke-PackageInstall` runs.

        To avoid actually executing each bundle's installers when we
        only want to *read* the declarative collection, we patch
        Invoke-PackageInstall in the child runspace to be a no-op
        capture function. Bundles that have not yet been migrated to
        the declarative form (i.e. don't assign a `$Packages` variable)
        contribute nothing — they are silently skipped, not errors.

        The repo's bucket/ directory is auto-detected by walking up from
        the loaded module's location. Override with $env:SCOOPBUCKET_BUCKET_PATH.
    .PARAMETER BucketPath
        Override the auto-detected bucket directory.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [string]$BucketPath
    )

    if (-not $BucketPath) {
        if ($env:SCOOPBUCKET_BUCKET_PATH) {
            $BucketPath = $env:SCOOPBUCKET_BUCKET_PATH
        } else {
            # Module lives at <repo>/module/ScoopBucket/. Walk up two.
            $moduleDir = $PSScriptRoot                                # …/Private
            $moduleRoot = Split-Path -Parent $moduleDir               # …/ScoopBucket
            $modulesParent = Split-Path -Parent $moduleRoot           # …/module
            $repoRoot = Split-Path -Parent $modulesParent             # …
            $candidate = Join-Path $repoRoot 'bucket'
            if (Test-Path $candidate) { $BucketPath = $candidate }
        }
    }

    if (-not $BucketPath -or -not (Test-Path $BucketPath)) {
        Write-Verbose "Get-BundlePackages: bucket directory not found (looked for $BucketPath). Returning empty."
        return @()
    }

    $bundles = Get-ChildItem -Path $BucketPath -Filter '*.ps1' -File |
        Where-Object { $_.Name -notmatch '\.Tests\.ps1$' } |
        Where-Object { $_.Name -ne 'Utils.ps1' -and $_.Name -ne 'Invoke-Tests.ps1' }

    $modulePsd1 = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'ScoopBucket\ScoopBucket.psd1'

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($bundle in $bundles) {
        $bundleName = [System.IO.Path]::GetFileNameWithoutExtension($bundle.Name)
        $captured = $null

        # Run the bundle in a child pwsh -NoProfile so it can't disturb
        # the current session, with a wrapper that overrides
        # Invoke-PackageInstall to capture instead of execute.
        $probe = @"
`$ErrorActionPreference='SilentlyContinue'
Import-Module '$modulePsd1' -ErrorAction SilentlyContinue

# Override the public driver in this child session so the bundle's
# installers never actually run. Capture the [Package[]] collection and
# emit JSON we can deserialize back in the parent.
function Invoke-PackageInstall {
    param([Parameter(Mandatory)][object[]]`$Packages, [Parameter(Mandatory)][string]`$Bundle, [Parameter(ValueFromRemainingArguments)]`$Remaining)
    `$exported = foreach (`$p in `$Packages) {
        @{
            Name        = `$p.Name
            Installer   = `$p.Installer
            Id          = `$p.Id
            Source      = `$p.Source
            Scope       = `$p.Scope
            CliCommands = @(`$p.CliCommands)
            Completion  = `$p.Completion
            DependsOn   = @(`$p.DependsOn)
            CISkip      = `$p.CISkip
            Notes       = `$p.Notes
        }
    }
    @{ Bundle = `$Bundle; Packages = @(`$exported) } | ConvertTo-Json -Depth 6 -Compress
    # Never call any real engine.
    return @()
}

# Stub helpers some bundles dot-source.
function Test-Command { param([string]`$c) `$null -ne (Get-Command `$c -ErrorAction SilentlyContinue) }
function Install-BucketApp { param([Parameter(Mandatory)][string]`$Name) }
function Install-LocalManifest { param() }
function Invoke-CliCompletionsSweep { param() }
function Register-CliCompletion { param() }

try {
    & '$($bundle.FullName)' 2>`$null
} catch {
    # Swallow bundle errors — we only care about the JSON capture.
    Write-Host '__SCOOPBUCKET_BUNDLE_ERROR__'
}
"@

        $tmp = Join-Path $env:TEMP "ScoopBucket-getbundle-$bundleName-$PID.ps1"
        try {
            Set-Content -Path $tmp -Value $probe -Encoding UTF8
            $pwsh = (Get-Process -Id $PID).Path
            if (-not $pwsh) { $pwsh = 'pwsh' }
            $output = & $pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $tmp 2>$null
            $jsonLine = $output | Where-Object { $_ -match '^\s*\{' } | Select-Object -First 1
            if ($jsonLine) {
                $captured = $jsonLine | ConvertFrom-Json -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Verbose "Get-BundlePackages: $bundleName probe threw: $($_.Exception.Message)"
        } finally {
            Remove-Item -Path $tmp -ErrorAction Ignore
        }

        if ($captured -and $captured.Packages) {
            $results.Add([pscustomobject]@{
                Bundle     = $captured.Bundle
                BundlePath = $bundle.FullName
                Packages   = @($captured.Packages)
            })
        } else {
            # Not yet migrated; surface as empty so callers can report
            # incomplete coverage rather than silently dropping the bundle.
            $results.Add([pscustomobject]@{
                Bundle     = $bundleName
                BundlePath = $bundle.FullName
                Packages   = @()
            })
        }
    }

    return ,$results.ToArray()
}
