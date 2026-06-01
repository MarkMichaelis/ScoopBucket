function Uninstall-Package {
    <#
    .SYNOPSIS
        Companion to Install-Package: uninstall one (or more) named
        packages from any bundle in this bucket and clean up the
        completion sentinel block each install wrote to
        $PROFILE.AllUsersAllHosts.

    .DESCRIPTION
        Mirrors Install-Package's name-resolution model:
          (a) Package.Name match within a declarative bundle.
          (b) Bundle-name match — uninstall every package in the bundle.
          (c) Bare manifest fallback — `<name>.json` with no declarative
              owner: there is no metadata to drive an engine-specific
              uninstall, so we surface a Skipped record with a reason.

        For each resolved package the dispatch goes through
        Invoke-PackageUninstall (which runs the per-installer presence
        probe, dispatches to the engine, and strips the sentinel
        completion block — unless -KeepCompletion).

        Emits one [PackageResult] per package (Operation='Uninstall') on
        the success stream, rendered by the format.ps1xml view; Status ∈
        Uninstalled | NotInstalled | Failed | Skipped.

    .PARAMETER Name
        One or more package or bundle names.

    .PARAMETER DryRun
        Plan only — no engine is actually invoked. Profile is not modified.

    .PARAMETER KeepCompletion
        Preserve the sentinel completion block in the AllUsersAllHosts
        profile. By default the block is removed.

    .PARAMETER SkipCompletion
        Don't touch the profile at all (overrides -KeepCompletion).

    .PARAMETER BucketPath
        Override the auto-detected bucket directory.

    .EXAMPLE
        Uninstall-Package -Name 'ripgrep'

    .EXAMPLE
        Uninstall-Package -Name 'OSBasePackages' -DryRun
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([PackageResult])]
    param(
        [Parameter(Mandatory, Position = 0)][string[]]$Name,
        [switch]$DryRun,
        [switch]$KeepCompletion,
        [switch]$SkipCompletion,
        [string]$BucketPath
    )

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

    $byBundle      = @{}          # BundlePath -> @{ Bundle; BundlePath; Names = [List[string]] }
    $fullBundles   = New-Object System.Collections.Generic.List[object]
    $manifestNames = New-Object System.Collections.Generic.List[string]

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
                    # Cascade: include the requested package AND every
                    # package transitively reachable via Companions in
                    # the same bundle. Cascade is restricted to
                    # Companions only -- we deliberately do NOT walk
                    # reverse-DependsOn (so uninstalling '.NET SDK'
                    # does not auto-yank every dotnet tool).
                    $byNameInBundle = @{}
                    foreach ($q in $b.Packages) { $byNameInBundle[$q.Name] = $q }
                    $seen  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    $queue = [System.Collections.Generic.Queue[string]]::new()
                    [void]$queue.Enqueue($p.Name)
                    while ($queue.Count -gt 0) {
                        $cur = $queue.Dequeue()
                        if (-not $seen.Add($cur)) { continue }
                        $byBundle[$b.BundlePath].Names.Add($cur)
                        $owner = $byNameInBundle[$cur]
                        if ($owner -and $owner.Companions) {
                            foreach ($comp in $owner.Companions) {
                                if ($byNameInBundle.ContainsKey($comp)) {
                                    [void]$queue.Enqueue($comp)
                                }
                            }
                        }
                    }
                    $found = $true
                    break
                }
            }
            if ($found) { break }
        }
        if ($found) { continue }

        $bundleMatch = $null
        foreach ($key in $bundleIndex.Keys) {
            if ($key -ieq $needed) { $bundleMatch = $bundleIndex[$key]; break }
        }
        if ($bundleMatch) {
            $fullBundles.Add($bundleMatch)
            continue
        }

        if ($effectiveBucket) {
            $manifestPath = Join-Path $effectiveBucket ("$needed.json")
            if (Test-Path $manifestPath) {
                $manifestNames.Add($needed)
                continue
            }
        }

        throw "Uninstall-Package: no bundle declares a package named '$needed' and no '$needed.json' manifest was found in the bucket."
    }

    # Build a [Package[]] for each touched bundle. We dot-source the
    # bundle in-process so CustomUninstallScript scriptblocks survive
    # (Get-BundlePackages serializes via JSON and drops scriptblocks).
    # Invoke-PackageUninstall emits PackageResult objects straight onto the
    # pipeline, so they all render through the single shared format view.
    foreach ($entry in $byBundle.Values) {
        $pkgObjects = @(Get-BundlePackageObjects -BundlePath $entry.BundlePath)
        if ($pkgObjects.Count -eq 0) {
            # Bundle's $Packages isn't dot-source-loadable from here.
            # Fall back to metadata-only reconstruction (no scriptblocks);
            # CustomUninstallScript paths will surface as Skipped.
            $b = $bundles | Where-Object BundlePath -eq $entry.BundlePath | Select-Object -First 1
            $pkgObjects = @($b.Packages | ForEach-Object { ConvertTo-PackageFromMetadata $_ })
        }
        Write-UpdateStatus -Activity 'Uninstall-Package' "Uninstall-Package: dispatching $($entry.Names -join ', ') via $($entry.Bundle)..."
        Invoke-PackageUninstall -Packages $pkgObjects -Bundle $entry.Bundle `
            -Name @($entry.Names) -DryRun:$DryRun -KeepCompletion:$KeepCompletion -SkipCompletion:$SkipCompletion `
            -ErrorAction Continue
    }

    foreach ($b in $fullBundles) {
        $pkgObjects = @(Get-BundlePackageObjects -BundlePath $b.BundlePath)
        if ($pkgObjects.Count -eq 0) {
            $pkgObjects = @($b.Packages | ForEach-Object { ConvertTo-PackageFromMetadata $_ })
        }
        Write-UpdateStatus -Activity 'Uninstall-Package' "Uninstall-Package: dispatching bundle '$($b.Bundle)' (all packages)..."
        Invoke-PackageUninstall -Packages $pkgObjects -Bundle $b.Bundle `
            -DryRun:$DryRun -KeepCompletion:$KeepCompletion -SkipCompletion:$SkipCompletion `
            -ErrorAction Continue
    }

    foreach ($n in $manifestNames) {
        Write-UpdateStatus -Activity 'Uninstall-Package' "Uninstall-Package: '$n' is a bare manifest (no declarative [Package] match); no uninstall metadata."
        [PackageResult]@{
            Operation = 'Uninstall'
            Status    = 'Skipped'
            Name      = $n
            Installer = $null
            Id        = $n
            Scope     = $null
            Bundle    = $null
            Reason    = 'Bare manifest; no Package metadata to drive uninstall.'
            Error     = $null
        }
    }
}
