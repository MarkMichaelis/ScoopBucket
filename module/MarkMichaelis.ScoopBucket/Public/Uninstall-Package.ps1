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

        Returns one PSCustomObject per package with:
          Bundle, Name, Installer, Id, Scope, State, Reason
        where State ∈ Uninstalled | NotInstalled | Failed | Skipped.

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
    [OutputType([object[]])]
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

    $allRecords = New-Object System.Collections.Generic.List[object]

    # Build a [Package[]] for each touched bundle. We dot-source the
    # bundle in-process so CustomUninstallScript scriptblocks survive
    # (Get-BundlePackages serializes via JSON and drops scriptblocks).
    foreach ($entry in $byBundle.Values) {
        $pkgObjects = @(Get-BundlePackageObjects -BundlePath $entry.BundlePath)
        if ($pkgObjects.Count -eq 0) {
            # Bundle's $Packages isn't dot-source-loadable from here.
            # Fall back to metadata-only reconstruction (no scriptblocks);
            # CustomUninstallScript paths will surface as Skipped.
            $b = $bundles | Where-Object BundlePath -eq $entry.BundlePath | Select-Object -First 1
            $pkgObjects = @($b.Packages | ForEach-Object { ConvertTo-PackageFromMetadata $_ })
        }
        Write-Host ""
        Write-Host "Uninstall-Package: dispatching $($entry.Names -join ', ') via $($entry.Bundle)..."
        $records = Invoke-PackageUninstall -Packages $pkgObjects -Bundle $entry.Bundle `
            -Name @($entry.Names) -DryRun:$DryRun -KeepCompletion:$KeepCompletion -SkipCompletion:$SkipCompletion
        foreach ($r in @($records)) { $allRecords.Add($r) }
    }

    foreach ($b in $fullBundles) {
        $pkgObjects = @(Get-BundlePackageObjects -BundlePath $b.BundlePath)
        if ($pkgObjects.Count -eq 0) {
            $pkgObjects = @($b.Packages | ForEach-Object { ConvertTo-PackageFromMetadata $_ })
        }
        Write-Host ""
        Write-Host "Uninstall-Package: dispatching bundle '$($b.Bundle)' (all packages)..."
        $records = Invoke-PackageUninstall -Packages $pkgObjects -Bundle $b.Bundle `
            -DryRun:$DryRun -KeepCompletion:$KeepCompletion -SkipCompletion:$SkipCompletion
        foreach ($r in @($records)) { $allRecords.Add($r) }
    }

    foreach ($n in $manifestNames) {
        Write-Host ""
        Write-Host "Uninstall-Package: '$n' is a bare manifest (no declarative [Package] match); no uninstall metadata."
        $allRecords.Add([pscustomobject]@{
            Bundle    = $null
            Name      = $n
            Installer = $null
            Id        = $n
            Scope     = $null
            State     = 'Skipped'
            Reason    = 'Bare manifest; no Package metadata to drive uninstall.'
        })
    }

    return ,$allRecords.ToArray()
}

function ConvertTo-PackageFromMetadata {
    <#
    .SYNOPSIS
        Internal: rebuild a [Package] from the JSON-deserialized metadata
        Get-BundlePackages returns. Scriptblock-typed fields are lost
        (they round-tripped through ConvertTo-Json) — callers that need
        CustomUninstallScript must instead source the bundle via
        Get-BundlePackageObjects.
    #>
    param([Parameter(Mandatory)][object]$Metadata)

    $pkg = [Package]@{
        Name        = $Metadata.Name
        Installer   = $Metadata.Installer
        Id          = $Metadata.Id
        Source      = if ($Metadata.PSObject.Properties['Source']) { [string]$Metadata.Source } else { '' }
        Scope       = if ($Metadata.PSObject.Properties['Scope']) { [string]$Metadata.Scope } else { 'global' }
        CliCommands = @($Metadata.CliCommands)
        Completion  = if ($Metadata.PSObject.Properties['Completion']) { [string]$Metadata.Completion } else { 'none' }
        DependsOn   = @($Metadata.DependsOn)
        Companions  = if ($Metadata.PSObject.Properties['Companions']) { @($Metadata.Companions) } else { @() }
        CISkip      = if ($Metadata.PSObject.Properties['CISkip']) { [string]$Metadata.CISkip } else { '' }
        Notes       = if ($Metadata.PSObject.Properties['Notes']) { [string]$Metadata.Notes } else { '' }
        # WingetExtraArgs must round-trip through the metadata-only
        # fallback or winget upgrade/uninstall commands lose declared
        # extras like --skip-dependencies (the very reason a bundle
        # bothered to set the field). Get-BundlePackages emits this
        # field in the probe projection; copy it back here.
        WingetExtraArgs = if ($Metadata.PSObject.Properties['WingetExtraArgs']) { @($Metadata.WingetExtraArgs) } else { @() }
    }
    # Completion's ExpectedCompletions invariant only matters at install
    # time; reconstruct enough to satisfy Validate() for non-'none' modes.
    if ($pkg.Completion -ne 'none') {
        $ec = @{}
        foreach ($cli in $pkg.CliCommands) { $ec[$cli] = @('--help') }
        $pkg.ExpectedCompletions = $ec
        # Validate() requires a NativeCommandScript for native/auto. Since
        # this is the uninstall path we never run it; supply a sentinel.
        if ($pkg.Completion -in @('native','auto')) {
            $pkg.NativeCommandScript = { '' }
        }
    }
    return $pkg
}
