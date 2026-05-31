function Update-Package {
    <#
    .SYNOPSIS
        Companion to Install-Package: update one (or more) named packages
        from any bundle in this bucket via each package's declared engine.

    .DESCRIPTION
        Mirrors Install-Package's name-resolution model with one extra
        wildcard shorthand:
          (*) The literal '*' expands to "every declarative package across
              every bundle in this bucket" (the bucket-wide update sweep).
          (a) Package.Name match within a declarative bundle.
          (b) Bundle-name match — update every package in the bundle.
          (c) Bare manifest fallback — `<name>.json` with no declarative
              owner: no metadata to drive a typed update; surface as
              Skipped with a reason.

        Use `-All` (mutually exclusive with `-Name`) to run a machine-wide
        sweep that bypasses bundle metadata entirely and dispatches each
        engine's native bulk-upgrade command (scoop update *, winget
        upgrade --all, choco upgrade all, npm update -g, dotnet tool
        update -g --all). Engines that aren't installed are skipped; a
        per-engine failure does not abort the remaining sweeps.

        For each resolved package the dispatch goes through
        Invoke-PackageUpdate which:
          - Topologically sorts by DependsOn (does NOT auto-install
            missing prereqs — warns instead).
          - Runs the per-engine `Update-*Package` (or PostUpdateScript
            for Installer='custom').
          - Refreshes `$env:Path` and re-registers completion when a
            CLI version actually changed.

    .PARAMETER Name
        One or more package names, bundle names, or the literal '*'.
        Mutually exclusive with -All.

    .PARAMETER All
        Run a machine-wide update sweep across every engine this bucket
        knows about (scoop, winget, choco, npmGlobal, dotnetTool),
        independent of bundle metadata. Mutually exclusive with -Name.
        Completers are NOT auto-refreshed under -All; run
        `Update-PackageCompletion` manually if a CLI version bumped.

    .PARAMETER DryRun
        Plan only — engines receive -WhatIf and do not invoke the CLI.

    .PARAMETER SkipCompletion
        Don't re-register completion blocks after a successful update.

    .PARAMETER BucketPath
        Override the auto-detected bucket directory.

    .EXAMPLE
        Update-Package -Name 'ripgrep'

    .EXAMPLE
        Update-Package -Name '*' -DryRun

    .EXAMPLE
        Update-Package -Name 'OSBasePackages'

    .EXAMPLE
        Update-Package -All -DryRun
        # Plan a machine-wide update across every engine this bucket knows
        # about (scoop, winget, choco, npmGlobal, dotnetTool). Mutually
        # exclusive with -Name. Bundle metadata is bypassed entirely --
        # each engine's native bulk-upgrade command runs against every
        # package it knows about on the machine.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName', SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([Package])]
    param(
        [Parameter(ParameterSetName = 'ByName', Mandatory, Position = 0)][string[]]$Name,
        [Parameter(ParameterSetName = 'MachineWide', Mandatory)][switch]$All,
        [switch]$DryRun,
        [switch]$SkipCompletion,
        [string]$BucketPath
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
    if ($All) {
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
            -Name @($entry.Names) -DryRun:$DryRun -SkipCompletion:$SkipCompletion
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
            -DryRun:$DryRun -SkipCompletion:$SkipCompletion
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
