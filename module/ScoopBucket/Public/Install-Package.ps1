function Install-Package {
    <#
    .SYNOPSIS
        User-facing helper: install one (or a few) named packages from any
        bundle in this bucket, with full DependsOn closure.

    .DESCRIPTION
        Use Install-Package when you know what you want to install ("give
        me ripgrep") but don't care which bundle declared it. It walks
        every migrated bundle via Get-BundlePackages, finds the entry
        whose Name matches, and runs that bundle's Invoke-PackageInstall
        with the -Name filter so DependsOn pulls in prerequisites.

        Use Invoke-PackageInstall (the underlying driver) only from a
        bundle's `.ps1` file — that's where the declarative `[Package[]]`
        collection lives. Bundle scripts call it once at the bottom to
        install everything they declare; end-users should reach for
        Install-Package instead, which is bundle-agnostic.

        Unlike `PackageManagement\Install-Package` (OneGet) this helper:
          - only installs packages declared in this bucket's `$Packages`
            arrays (no PSGallery / NuGet fall-through);
          - takes our refactor's option shape, not OneGet's
            -ProviderName / -RequiredVersion / etc.;
          - the OneGet cmdlet remains reachable via its full
            module-qualified name (PackageManagement\Install-Package).

    .PARAMETER Name
        One or more package names (matched case-insensitively against
        Package.Name).

    .PARAMETER DryRun
        Plan only — log every action without invoking engines.

    .PARAMETER SkipCompletion
        Don't attempt completion registration.

    .PARAMETER BucketPath
        Override the auto-detected bucket directory.

    .EXAMPLE
        Install-Package -Name 'ripgrep'

    .EXAMPLE
        Install-Package -Name 'BitwardenCli' -DryRun
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0)][string[]]$Name,
        [switch]$DryRun,
        [switch]$SkipCompletion,
        [string]$BucketPath
    )

    $bundleArgs = @{}
    if ($BucketPath) { $bundleArgs['BucketPath'] = $BucketPath }
    $bundles = Get-BundlePackages @bundleArgs

    # Group every requested name by the bundle it lives in.
    $byBundle = @{}
    foreach ($needed in $Name) {
        $found = $false
        foreach ($b in $bundles) {
            foreach ($p in $b.Packages) {
                if ($p.Name -ieq $needed) {
                    if (-not $byBundle.ContainsKey($b.BundlePath)) {
                        $byBundle[$b.BundlePath] = @{
                            BundlePath = $b.BundlePath
                            Bundle     = $b.Bundle
                            Names      = [System.Collections.Generic.List[string]]::new()
                        }
                    }
                    $byBundle[$b.BundlePath].Names.Add($needed)
                    $found = $true
                    break
                }
            }
            if ($found) { break }
        }
        if (-not $found) {
            throw "Install-Package: no bundle declares a package named '$needed'."
        }
    }

    foreach ($entry in $byBundle.Values) {
        Write-Host ""
        Write-Host "Install-Package: dispatching $($entry.Names -join ', ') via $($entry.Bundle)..."
        # We dot-source the bundle but pre-override its
        # Invoke-PackageInstall call by hooking before it runs.
        # Simplest reliable approach: run the bundle's installer in a
        # child runspace with the bucket's module imported and an
        # injected -Name filter.

        $pwsh = (Get-Process -Id $PID).Path
        if (-not $pwsh) { $pwsh = 'pwsh' }
        $modulePsd1 = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'ScoopBucket\ScoopBucket.psd1'
        $namesJson = ($entry.Names | ConvertTo-Json -Compress)
        $flags = @()
        if ($DryRun)         { $flags += '-DryRun' }
        if ($SkipCompletion) { $flags += '-SkipCompletion' }
        $flagsStr = $flags -join ' '

        $launch = @"
`$ErrorActionPreference='Continue'
Import-Module '$modulePsd1' -Force
`$names = '$namesJson' | ConvertFrom-Json
`$realDriver = Get-Command Invoke-PackageInstall -Module ScoopBucket
function Invoke-PackageInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]`$Packages, [Parameter(Mandatory)][string]`$Bundle, [Parameter(ValueFromRemainingArguments)]`$Remaining)
    & `$realDriver -Packages `$Packages -Bundle `$Bundle -Name @(`$names) $flagsStr
}
& '$($entry.BundlePath)'
"@
        $tmp = Join-Path $env:TEMP "ScoopBucket-install-$($entry.Bundle)-$PID.ps1"
        try {
            Set-Content -Path $tmp -Value $launch -Encoding UTF8
            & $pwsh -NoProfile -ExecutionPolicy Bypass -File $tmp
        } finally {
            Remove-Item -Path $tmp -ErrorAction Ignore
        }
    }
}
