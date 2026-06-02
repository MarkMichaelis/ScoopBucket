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
    [OutputType([PackageResult])]
    param(
        [Parameter(Mandatory, Position = 0)][string[]]$Name,
        [switch]$DryRun,
        [switch]$SkipCompletion,
        # Show every package in the result table, including unchanged rows
        # (AlreadyInstalled / Skipped). By default only changed rows
        # (Installed / Failed) are shown and the rest are summarized in a
        # one-line host message. See #283.
        [switch]$IncludeUnchanged,
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

    # Track per-bundle errors across both dispatch loops so the sweep
    # cannot be aborted by a caller that runs with $ErrorActionPreference='Stop'
    # (which would otherwise upgrade Invoke-PackageInstall's non-terminating
    # WriteError into a terminating error at the call site). Mirrors the
    # resilient sweep Update-Package uses (#272).
    $pkgErrors = [System.Collections.Generic.List[object]]::new()

    # Collect every PackageResult the driver emits so the summary view can
    # filter to changed rows and render a single table. See #283.
    $results = New-Object System.Collections.Generic.List[object]

    # --- Dispatch (a): Package.Name flow with -Name filter -----------------
    # In-process: reconstruct real [Package] objects from the bundle and call
    # the driver directly (same model Update-Package uses), so results flow
    # back as live PackageResult objects rendered once by the format view.
    foreach ($entry in $byBundle.Values) {
        $pkgObjects = @(Get-BundlePackageObjects -BundlePath $entry.BundlePath)
        $results.AddRange([object[]]@(
            Invoke-PackageInstall -Packages $pkgObjects -Bundle $entry.Bundle `
                -Name @($entry.Names) -DryRun:$DryRun -SkipCompletion:$SkipCompletion `
                -ErrorAction Continue -ErrorVariable +pkgErrors))
    }

    # --- Dispatch (b): full-bundle install (no -Name filter) ---------------
    foreach ($b in $fullBundles) {
        Write-UpdateStatus -Activity 'Install-Package' "Install-Package: dispatching bundle '$($b.Bundle)' (all packages)..."
        $pkgObjects = @(Get-BundlePackageObjects -BundlePath $b.BundlePath)
        $results.AddRange([object[]]@(
            Invoke-PackageInstall -Packages $pkgObjects -Bundle $b.Bundle `
                -DryRun:$DryRun -SkipCompletion:$SkipCompletion `
                -ErrorAction Continue -ErrorVariable +pkgErrors))
    }

    # --- Dispatch (c): scoop install fallback for bare manifests -----------
    # Some bare `<name>.json` manifests are ALSO declared by a [Package] in a
    # bundle via its Id (with the owner prefix stripped -- e.g. the package
    # whose Id is 'MarkMichaelis/VisualStudio2026Enterprise' declares the
    # 'VisualStudio2026Enterprise.json' manifest). Those packages carry the
    # completion metadata (CliCommands / Completion / NativeCommandScript) that
    # path (a) would register when installed by Package.Name. Resolve that
    # declaring [Package] after the install so reaching a manifest by its
    # *manifest* name registers the same completers path (a) does. Manifests
    # with no declaring [Package] are genuinely metadata-less and dispatch as a
    # plain `scoop install` with no completion (#291).
    $manifestPackagesToImport = New-Object System.Collections.Generic.List[object]
    foreach ($n in $manifestNames) {
        Write-UpdateStatus -Activity 'Install-Package' "Install-Package: dispatching manifest '$n' via scoop install (no declarative [Package] match)..."
        if ($DryRun) {
            Write-UpdateStatus -Activity 'Install-Package' "  [DryRun] scoop install $n"
            continue
        }
        # Honor -WhatIf / -Confirm for the bare-manifest path too, so it is
        # consistent with paths (a)/(b) which gate every engine call through
        # Invoke-PackageInstall. Under -WhatIf this prints the standard
        # "What if" line and skips both the install and the completion work.
        if (-not $PSCmdlet.ShouldProcess($n, 'scoop install')) { continue }
        # Delegate to scoop. We pass the bare name (assumes the
        # MarkMichaelis bucket has been added — see
        # `Install-Package AddMarkMichaelisScoopBucket`); scoop will
        # resolve and run the manifest's installer.script.
        & scoop install $n
        # Capture scoop's exit status BEFORE any other command can clobber
        # $LASTEXITCODE. A failed install must not register completers for a
        # CLI that was never actually installed. Treat a null exit code (no
        # native command ran, e.g. a stubbed scoop) as success so the
        # best-effort registration still fires in that case.
        $installExit = $global:LASTEXITCODE

        if (-not $SkipCompletion -and ($null -eq $installExit -or $installExit -eq 0)) {
            # Find the declarative [Package] (if any) whose Id base name
            # matches this manifest. The Id may carry an owner/bucket prefix
            # ('<owner>/<manifest>'); the manifest base name is the segment
            # after the last '/'.
            $declaring = $null
            foreach ($b in $bundles) {
                foreach ($p in $b.Packages) {
                    if (-not $p.Id) { continue }
                    $manifestBase = ($p.Id -split '/')[-1]
                    if ($manifestBase -ieq $n -and $p.Completion -ne 'none') {
                        $declaring = $p
                        break
                    }
                }
                if ($declaring) { break }
            }

            if ($declaring -and $declaring.CliCommands -and $declaring.CliCommands.Count -gt 0) {
                # Persistent sentinel-block registration -- mirrors the path (a)
                # flow in Invoke-PackageInstall so a fresh pwsh inherits the
                # completers on next startup.
                foreach ($cli in $declaring.CliCommands) {
                    $registerArgs = @{ Cli = $cli; Mode = $declaring.Completion }
                    if ($declaring.NativeCommandScript) { $registerArgs['NativeCommand'] = $declaring.NativeCommandScript }
                    # Prefer the loader's pre-captured native completer text
                    # (NativeCommandOutputs[$cli]) when present -- the live
                    # NativeCommandScript scriptblock is stripped by the
                    # Get-BundlePackages JSON round-trip.
                    if ($declaring.PSObject.Properties.Name -contains 'NativeCommandOutputs' -and $declaring.NativeCommandOutputs) {
                        $no = $declaring.NativeCommandOutputs
                        $preCaptured = $null
                        if ($no -is [hashtable] -and $no.ContainsKey($cli)) {
                            $preCaptured = [string]$no[$cli]
                        } elseif ($no.PSObject -and ($no.PSObject.Properties.Name -contains $cli)) {
                            $preCaptured = [string]$no.$cli
                        }
                        if ($preCaptured -and $preCaptured.Trim()) {
                            $registerArgs['PreCapturedNative'] = $preCaptured
                        }
                    }
                    try {
                        $null = Register-PackageCompletion @registerArgs
                    } catch {
                        Write-Warning "  $n/$cli completion registration failed: $($_.Exception.Message)"
                    }
                }
                # Queue the declaring package for in-session import below.
                [void]$manifestPackagesToImport.Add($declaring)
            }
        }
    }

    # --- Post-install: register completers in the caller's session ---------
    # Register-PackageCompletion writes sentinel blocks to
    # $PROFILE.AllUsersAllHosts in the child pwsh that runs the bundle;
    # those blocks only auto-load on the next pwsh startup. To save users
    # the "open a fresh terminal" dance, re-resolve each just-installed
    # CLI's completion source from the declarative [Package] data and
    # invoke Register-ArgumentCompleter directly in the current session.
    # Register-ArgumentCompleter -Native is process-global so this works
    # regardless of module scope.
    if (-not $SkipCompletion -and -not $DryRun) {
        # NOTE: List[object] (not List[Package]) because $b.Packages items
        # are JSON-deserialized PSCustomObjects from Get-BundlePackages'
        # child runspace, not real [Package] instances. PowerShell can't
        # coerce PSCustomObject -> Package, so List[Package].Add throws
        # "Cannot find an overload for 'Add' and the argument count: '1'".
        # Import-PackageCompletion only reads property names off the
        # objects, so PSCustomObject works fine downstream.
        $packagesToImport = New-Object System.Collections.Generic.List[object]
        foreach ($entry in $byBundle.Values) {
            foreach ($b in $bundles) {
                if ($b.BundlePath -ne $entry.BundlePath) { continue }
                foreach ($p in $b.Packages) {
                    if ($entry.Names -contains $p.Name -and $p.Completion -ne 'none') {
                        [void]$packagesToImport.Add($p)
                    }
                }
            }
        }
        foreach ($b in $fullBundles) {
            foreach ($p in $b.Packages) {
                if ($p.Completion -ne 'none') { [void]$packagesToImport.Add($p) }
            }
        }
        # Path (c): packages whose manifest was installed via `scoop install`
        # but that a bundle declares via Id (#291). Already filtered to
        # Completion != 'none' and CliCommands present in the dispatch loop.
        foreach ($p in $manifestPackagesToImport) {
            [void]$packagesToImport.Add($p)
        }
        if ($packagesToImport.Count -gt 0) {
            $imported = Import-PackageCompletion -Package $packagesToImport
            $ok = @($imported | Where-Object Action -eq 'Registered')
            if ($ok.Count -gt 0) {
                Write-Host ""
                Write-Host "Install-Package: registered completers in current session for: $(($ok.Cli) -join ', ')"
            }
        }
    }

    # Emit the collected results through the summary view: changed rows only by
    # default (with a one-line host summary of the rest), or every row under
    # -IncludeUnchanged. See #283.
    Select-PackageResultSummary -Result $results.ToArray() -IncludeUnchanged:$IncludeUnchanged
}
