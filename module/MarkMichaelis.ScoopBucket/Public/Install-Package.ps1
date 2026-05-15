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

    # Resolve the effective bucket directory once for manifest fallbacks
    # below (case (c) — `scoop install <name>` for bare json manifests
    # and imperative `.ps1` bundles).
    $effectiveBucket = $BucketPath
    if (-not $effectiveBucket) {
        $effectiveBucket = Resolve-BucketPath -CallerScriptRoot $PSScriptRoot
    }

    # Index lookups: bundle name → bundle entry (only declarative bundles
    # i.e. bundles with at least one [Package] captured by
    # Get-BundlePackages); package name → bundle entry.
    $bundleIndex = @{}
    foreach ($b in $bundles) {
        if ($b.Packages -and $b.Packages.Count -gt 0) {
            $bundleIndex[$b.Bundle] = $b
        }
    }

    # Classify each requested name into one of three dispatch buckets:
    #   ByName    — Package.Name match within a declarative bundle.
    #               Carries forward existing -Name-filtered dispatch.
    #   FullBundle — Bundle name match (declarative bundle, install
    #               every package it declares).
    #   Manifest  — `<name>.json` exists but no [Package] match and no
    #               declarative-bundle match. Falls through to
    #               `scoop install <name>` so the manifest's
    #               `installer.script` runs verbatim.
    $byBundle      = @{}
    $fullBundles   = New-Object System.Collections.Generic.List[object]
    $manifestNames = New-Object System.Collections.Generic.List[string]

    foreach ($needed in $Name) {
        # (a) Exact Package.Name match wins over bundle / manifest
        # matches — most precise intent, and what the historical contract
        # already implied.
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
                    $byBundle[$b.BundlePath].Names.Add($p.Name)
                    $found = $true
                    break
                }
            }
            if ($found) { break }
        }
        if ($found) { continue }

        # (b) Bundle name match — install every package in the bundle.
        $bundleMatch = $null
        foreach ($key in $bundleIndex.Keys) {
            if ($key -ieq $needed) { $bundleMatch = $bundleIndex[$key]; break }
        }
        if ($bundleMatch) {
            $fullBundles.Add($bundleMatch)
            continue
        }

        # (c) Bare manifest fallback — any `<name>.json` we haven't
        # otherwise classified, including imperative `.ps1` bundles
        # (Chocolatey, Gemini, ClaudeExcel, PowerShell, ...) whose
        # `Get-BundlePackages` Packages array is empty.
        if ($effectiveBucket) {
            $manifestPath = Join-Path $effectiveBucket ("$needed.json")
            if (Test-Path $manifestPath) {
                $manifestNames.Add($needed)
                continue
            }
        }

        throw "Install-Package: no bundle declares a package named '$needed' and no '$needed.json' manifest was found in the bucket."
    }

    # --- Dispatch (a): Package.Name flow with -Name filter -----------------
    foreach ($entry in $byBundle.Values) {
        Invoke-BundleScript -BundlePath $entry.BundlePath -Bundle $entry.Bundle `
            -Names $entry.Names -DryRun:$DryRun -SkipCompletion:$SkipCompletion
    }

    # --- Dispatch (b): full-bundle install (no -Name filter) ---------------
    foreach ($b in $fullBundles) {
        Write-Host ""
        Write-Host "Install-Package: dispatching bundle '$($b.Bundle)' (all packages)..."
        Invoke-BundleScript -BundlePath $b.BundlePath -Bundle $b.Bundle `
            -DryRun:$DryRun -SkipCompletion:$SkipCompletion
    }

    # --- Dispatch (c): scoop install fallback for bare manifests -----------
    foreach ($n in $manifestNames) {
        Write-Host ""
        Write-Host "Install-Package: dispatching manifest '$n' via scoop install (no declarative [Package] match)..."
        if ($DryRun) {
            Write-Host "  [DryRun] scoop install $n"
            continue
        }
        # Delegate to scoop. We pass the bare name (assumes the
        # MarkMichaelis bucket has been added — see
        # `Install-Package AddMarkMichaelisScoopBucket`); scoop will
        # resolve and run the manifest's installer.script.
        & scoop install $n
    }
}
