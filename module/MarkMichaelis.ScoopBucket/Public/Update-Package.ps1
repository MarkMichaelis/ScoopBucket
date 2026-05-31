function Update-Package {
    <#
    .SYNOPSIS
        Update packages declared by this bucket (default), or update every
        installed package on the machine across all supported engines
        (-MachineWide).

    .DESCRIPTION
        Two operating modes:

        1) Bucket-scoped (default, -Name). Mirrors Install-Package's
           name-resolution model with one extra wildcard shorthand:
             (*) The literal '*' expands to "every declarative package across
                 every bundle in this bucket" (the bucket-wide update sweep).
             (a) Package.Name match within a declarative bundle.
             (b) Bundle-name match — update every package in the bundle.
             (c) Bare manifest fallback — `<name>.json` with no declarative
                 owner: no metadata to drive a typed update; surface as
                 Skipped with a reason.

           This mode operates ONLY on packages declared in this bucket's
           bundles. To update every installed package on the machine
           regardless of source, use -MachineWide.

        2) Machine-wide (-MachineWide, mutually exclusive with -Name).
           Sweeps every package manager this module knows about — winget,
           scoop, chocolatey, npm (global), and dotnet tools — and runs
           that engine's bulk-upgrade command. **This updates EVERY installed
           package the engine knows about on the local machine, INCLUDING
           packages that were NOT installed by this bucket.** Bundle metadata
           is bypassed entirely; DependsOn, PostInstallScript,
           PostUpdateScript, and CISkip have no effect in this mode.
           Tab-completers are not refreshed automatically — run
           Update-PackageCompletion afterwards if you need the latest CLI
           completers. Engines that aren't installed on the machine are
           skipped silently with a Skipped row in the summary; a per-engine
           failure does not abort the remaining sweeps.

        For each resolved package in bucket-scoped mode the dispatch goes
        through Invoke-PackageUpdate which:
          - Topologically sorts by DependsOn (does NOT auto-install
            missing prereqs — warns instead).
          - Runs the per-engine `Update-*Package` (or PostUpdateScript
            for Installer='custom').
          - Refreshes `$env:Path` and re-registers completion when a
            CLI version actually changed.

        Before any per-app scoop update runs in bucket-scoped mode, the
        scoop bucket clones under ~/scoop/buckets/<name> are refreshed
        once (`scoop update` with no args) so that per-app updates see
        the latest manifests rather than a stale local mirror. See #267.
        Suppress with -SkipBucketRefresh.

    .PARAMETER Name
        One or more package names, bundle names, or the literal '*'.
        Operates ONLY on packages declared in this bucket's bundles.
        Mutually exclusive with -MachineWide. To update every installed
        package on the machine regardless of source, use **-MachineWide**.

    .PARAMETER MachineWide
        Run a machine-wide update sweep across every engine this module
        knows about, independent of bundle metadata. This updates EVERY
        installed package the engine knows about on the local machine,
        INCLUDING packages that were NOT installed by this bucket.
        Mutually exclusive with -Name.

        The five engine commands invoked (in order: scoop, winget, choco,
        npmGlobal, dotnetTool) are:
          - winget upgrade --all --include-unknown --silent --accept-package-agreements --accept-source-agreements
          - scoop update *
          - choco upgrade all -y --no-progress
          - npm update -g
          - dotnet tool update -g --all   (with per-tool fallback on older SDKs)

        An engine that is not installed on the machine is skipped silently
        with a Skipped row in the summary. Completers are NOT auto-refreshed
        under -MachineWide; run `Update-PackageCompletion` manually if a
        CLI version bumped.

    .PARAMETER DryRun
        Plan only — engines receive -WhatIf and do not invoke the CLI.

    .PARAMETER SkipCompletion
        Don't re-register completion blocks after a successful update.

    .PARAMETER SkipBucketRefresh
        Suppress the automatic ``scoop update`` (bucket refresh) that
        Update-Package runs once per invocation when the dispatch plan
        contains a scoop-engine package. Useful when callers know the
        local bucket clones are already current and want to shave the
        few-seconds refresh cost, or when running offline. Has no
        effect under -DryRun or -MachineWide (which bypass it already).

    .PARAMETER BucketPath
        Override the auto-detected bucket directory.

    .EXAMPLE
        Update-Package -Name 'ripgrep'

    .EXAMPLE
        Update-Package -Name '*' -DryRun

    .EXAMPLE
        Update-Package -Name 'OSBasePackages'

    .EXAMPLE
        Update-Package -MachineWide -DryRun
        # Plan a machine-wide update across every engine this module knows
        # about (winget, scoop, chocolatey, npm global, dotnet tools).
        # Mutually exclusive with -Name. Bundle metadata is bypassed --
        # each engine's native bulk-upgrade command runs against every
        # package it knows about on the machine, INCLUDING packages NOT
        # installed by this bucket.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName', SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([Package])]
    param(
        [Parameter(ParameterSetName = 'ByName', Mandatory, Position = 0)][string[]]$Name,
        [Parameter(ParameterSetName = 'MachineWide', Mandatory)]
        [switch]$MachineWide,
        [switch]$DryRun,
        [switch]$SkipCompletion,
        [switch]$SkipBucketRefresh,
        [string]$BucketPath,
        # Hard cap on per-package winget upgrade time (minutes). Default
        # 15 minutes; pass 0 to disable. Forwarded to Invoke-PackageUpdate
        # and only affects the winget engine. See #269.
        [int]$PackageTimeoutMinutes = 15
    )

    # Fold -WhatIf into -DryRun. Update-Package advertises
    # SupportsShouldProcess, so callers reasonably expect `Update-Package
    # foo -WhatIf` to plan-only. Without this, $WhatIfPreference would
    # not propagate to the engines (which key off $DryRun, mapped to
    # their own -WhatIf at dispatch time) and real updates would run.
    if ($WhatIfPreference -and -not $DryRun) { $DryRun = $true }

    # Machine-wide sweep: bypass bundle resolution entirely and dispatch
    # straight to each engine's native bulk-upgrade command. The hint at
    # the end of the run reminds users to run Update-PackageCompletion
    # manually since we can't tell which CLIs (if any) version-bumped.
    if ($MachineWide) {
        Invoke-AllEnginesUpdate -DryRun:$DryRun
        return
    }

    $bundleArgs = @{}
    if ($BucketPath) { $bundleArgs['BucketPath'] = $BucketPath }
    $bundles = Get-BundlePackages @bundleArgs

    $effectiveBucket = $BucketPath
    if (-not $effectiveBucket) {
        $effectiveBucket = Resolve-BucketPath -CallerScriptRoot $PSScriptRoot
    }

    $bundleIndex = @{}
    foreach ($b in $bundles) {
        if ($b.Packages -and $b.Packages.Count -gt 0) {
            $bundleIndex[$b.Bundle] = $b
        }
    }

    $byBundle      = @{}     # BundlePath -> @{ Bundle; BundlePath; Names = [List[string]] }
    $fullBundles   = New-Object System.Collections.Generic.List[object]
    $manifestNames = New-Object System.Collections.Generic.List[string]

    # First pass: '*' shorthand expands to every declarative bundle. Any
    # other names continue through the per-needed resolver below.
    $expanded = New-Object System.Collections.Generic.List[string]
    $starSeen = $false
    foreach ($n in $Name) {
        if ($n -eq '*') { $starSeen = $true; continue }
        $expanded.Add($n)
    }
    if ($starSeen) {
        # Hashtable enumeration order is unspecified, so a bucket-wide
        # `Update-Package *` sweep would log (and dispatch to) bundles
        # in a non-deterministic order. Sort by bundle name so the
        # transcript is stable run-to-run — useful when diffing dry-run
        # outputs across iterations and when downstream tooling parses
        # the summary table.
        foreach ($b in ($bundleIndex.Values | Sort-Object Bundle)) { $fullBundles.Add($b) }
    }

    foreach ($needed in $expanded) {
        # (a) Exact Package.Name match wins over bundle / manifest matches.
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

        # (b) Bundle-name match.
        $bundleMatch = $null
        foreach ($key in $bundleIndex.Keys) {
            if ($key -ieq $needed) { $bundleMatch = $bundleIndex[$key]; break }
        }
        if ($bundleMatch) {
            $fullBundles.Add($bundleMatch)
            continue
        }

        # (c) Bare manifest fallback — no declarative metadata, surface as Skipped.
        if ($effectiveBucket) {
            $manifestPath = Join-Path $effectiveBucket ("$needed.json")
            if (Test-Path $manifestPath) {
                $manifestNames.Add($needed)
                continue
            }
        }

        throw "Update-Package: no bundle declares a package named '$needed' and no '$needed.json' manifest was found in the bucket."
    }

    # De-duplicate $fullBundles by BundlePath (a '*' sweep plus an
    # explicit bundle name could otherwise double-process a bundle).
    if ($fullBundles.Count -gt 1) {
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $dedup = New-Object System.Collections.Generic.List[object]
        foreach ($fb in $fullBundles) {
            if ($seen.Add($fb.BundlePath)) { [void]$dedup.Add($fb) }
        }
        $fullBundles = $dedup
    }

    # Cross-dedup: when a bundle appears in both $fullBundles (full sweep
    # or explicit bundle-name match) AND $byBundle (an individual package
    # within that same bundle was also named), the full-bundle dispatch
    # subsumes the per-name dispatch. Drop the $byBundle entry so we don't
    # update the same package twice in the same Update-Package call.
    if ($fullBundles.Count -gt 0 -and $byBundle.Count -gt 0) {
        $fullPaths = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@($fullBundles | ForEach-Object { $_.BundlePath }),
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($key in @($byBundle.Keys)) {
            if ($fullPaths.Contains($key)) { [void]$byBundle.Remove($key) }
        }
    }

    # Auto bucket refresh (#267). When the dispatch plan contains any
    # scoop-engine package, refresh scoop's bucket clones ONCE before the
    # per-app updates. Without this, a stale per-bucket clone under
    # ~/scoop/buckets/<name> serves the previous manifest version, and a
    # per-app `scoop update <app>` can fail (e.g. the 404 in #265 that
    # persisted across user `Update-Package` runs because the local
    # bucket clone hadn't fast-forwarded). Gated:
    #   * Skipped under -DryRun (refresh has no plan/apply distinction;
    #     a dry run shouldn't have engine side effects).
    #   * Skipped under -SkipBucketRefresh (escape hatch).
    #   * Skipped when no scoop packages are in scope.
    # A failed refresh does not abort dispatch -- we surface a warning
    # and continue; per-app updates may still succeed if they happen to
    # already have the latest manifest cached.
    if (-not $DryRun -and -not $SkipBucketRefresh) {
        $scoopInScope = $false
        foreach ($entry in $byBundle.Values) {
            $pkgObjects = @(Get-BundlePackageObjects -BundlePath $entry.BundlePath)
            if ($pkgObjects.Count -eq 0) {
                $b = $bundles | Where-Object BundlePath -eq $entry.BundlePath | Select-Object -First 1
                $pkgObjects = @($b.Packages | ForEach-Object { ConvertTo-PackageFromMetadata $_ })
            }
            if ($pkgObjects | Where-Object { $_.Installer -eq 'scoop' -and ($entry.Names -contains $_.Name) } | Select-Object -First 1) {
                $scoopInScope = $true; break
            }
        }
        if (-not $scoopInScope) {
            foreach ($b in $fullBundles) {
                $pkgObjects = @(Get-BundlePackageObjects -BundlePath $b.BundlePath)
                if ($pkgObjects.Count -eq 0) {
                    $pkgObjects = @($b.Packages | ForEach-Object { ConvertTo-PackageFromMetadata $_ })
                }
                if ($pkgObjects | Where-Object Installer -eq 'scoop' | Select-Object -First 1) {
                    $scoopInScope = $true; break
                }
            }
        }
        if ($scoopInScope) {
            $refresh = Update-ScoopBucket
            if ($refresh.State -eq 'Failed') {
                Write-Warning "Update-Package: scoop bucket refresh failed ($($refresh.Reason)); per-app updates may use stale manifests."
            }
        }
    }

    # Dispatch (a): selective per-bundle Name filter.
    foreach ($entry in $byBundle.Values) {
        $pkgObjects = @(Get-BundlePackageObjects -BundlePath $entry.BundlePath)
        if ($pkgObjects.Count -eq 0) {
            $b = $bundles | Where-Object BundlePath -eq $entry.BundlePath | Select-Object -First 1
            $pkgObjects = @($b.Packages | ForEach-Object { ConvertTo-PackageFromMetadata $_ })
        }
        Write-Host ""
        Write-Host "Update-Package: dispatching $($entry.Names -join ', ') via $($entry.Bundle)..."
        Invoke-PackageUpdate -Packages $pkgObjects -Bundle $entry.Bundle `
            -Name @($entry.Names) -DryRun:$DryRun -SkipCompletion:$SkipCompletion `
            -PackageTimeoutMinutes $PackageTimeoutMinutes
    }

    # Dispatch (b): full-bundle update.
    foreach ($b in $fullBundles) {
        $pkgObjects = @(Get-BundlePackageObjects -BundlePath $b.BundlePath)
        if ($pkgObjects.Count -eq 0) {
            $pkgObjects = @($b.Packages | ForEach-Object { ConvertTo-PackageFromMetadata $_ })
        }
        Write-Host ""
        Write-Host "Update-Package: dispatching bundle '$($b.Bundle)' (all packages)..."
        Invoke-PackageUpdate -Packages $pkgObjects -Bundle $b.Bundle `
            -DryRun:$DryRun -SkipCompletion:$SkipCompletion `
            -PackageTimeoutMinutes $PackageTimeoutMinutes
    }

    # Dispatch (c): bare manifests — no declarative [Package] metadata,
    # so no engine routing is possible. Surface as a Warning (the
    # documented "Skipped with a reason" outcome) instead of a quiet
    # Write-Host, so it survives -InformationAction SilentlyContinue
    # and shows up in CI logs.
    foreach ($n in $manifestNames) {
        Write-Warning "Update-Package: '$n' is a bare manifest with no declarative [Package] match; skipped because Update-Package requires declarative metadata to drive an engine update. Use 'scoop update $n' directly if needed."
    }
}
