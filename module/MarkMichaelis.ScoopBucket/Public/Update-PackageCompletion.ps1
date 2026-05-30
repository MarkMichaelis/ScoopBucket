function Update-PackageCompletion {
    <#
    .SYNOPSIS
        Repair / refresh tab-completion sentinel blocks for every
        Package in the bucket whose CliCommand is on PATH but has no
        block in $PROFILE.AllUsersAllHosts.

    .DESCRIPTION
        Solves two related "I have the CLI installed but `<cli> <Tab>`
        only completes file names" scenarios:

          (1) "I installed Bitwarden CLI, then installed PSCompletions,
              but `bw <Tab>` still only completes files." Originally
              Register-PackageCompletion fell through to its 'Skipped'
              branch because PSCompletions wasn't there yet.

          (2) "I restored my dev machine — the CLIs are back on PATH but
              $PROFILE.AllUsersAllHosts was not part of the backup, so
              no sentinel blocks exist." For native-completion CLIs
              (`gh`, `rg`, …) this used to require running the original
              Install-Package per bundle.

        Update-PackageCompletion walks every declarative bundle via
        Get-BundlePackages, finds Packages whose Completion mode is
        'pscompletions', 'native', or 'auto' (with or without a
        NativeCommandScript), confirms each CliCommand resolves via
        Get-Command, and calls Register-PackageCompletion when no block
        exists in the profile. Existing sentinel blocks are preserved
        unless -Force is passed.

        Native-mode repairs use the NativeCommandOutputs hashtable that
        Get-BundlePackages pre-captures in its child runspace — so the
        repair walks need no access to the original `<cli> completion
        powershell` command and no re-install.

        Called automatically by the PSCompletions bundle's
        PostInstallScript so `Install-Package PSCompletions` heals
        already-installed CLIs in one shot.

    .PARAMETER BucketPath
        Override the auto-detected bucket directory (forwarded to
        Get-BundlePackages).

    .PARAMETER Force
        Re-register every eligible CLI even when a sentinel block
        already exists. Without -Force, CLIs that already have a block
        are left alone.

    .PARAMETER ProfilePath
        Test hook: read/write this file instead of
        $PROFILE.AllUsersAllHosts. Bypasses elevation check.

    .OUTPUTS
        PSCustomObject[] — one record per (Cli, Package) candidate,
        with Cli, Package, Bundle, Mode, Action (Registered | Preserved
        | Skipped | WhatIf), Source (Native | PSCompletions | Skipped),
        and Reason fields.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject[]])]
    param(
        [string]$BucketPath,
        [switch]$Force,
        [string]$ProfilePath
    )

    $bundleArgs = @{}
    if ($BucketPath) { $bundleArgs['BucketPath'] = $BucketPath }
    $bundles = Get-BundlePackages @bundleArgs

    # Resolve the profile we will read for "block already exists?"
    # checks. When -ProfilePath supplied use it as-is; otherwise pull
    # the AllUsersAllHosts profile path WITHOUT the elevation check
    # — we only need to READ it here. Register-PackageCompletion will
    # do its own elevation check when it tries to WRITE.
    $profileTarget = $ProfilePath
    if (-not $profileTarget) { $profileTarget = $PROFILE.AllUsersAllHosts }
    $existingContent = ''
    if ($profileTarget -and (Test-Path $profileTarget)) {
        $raw = Get-Content -Path $profileTarget -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($null -ne $raw) { $existingContent = $raw }
    }

    $results = New-Object System.Collections.Generic.List[object]

    # Issue #223: front-load a single `psc update *` catalog refresh
    # whenever the resolved package set contains any pscompletions-mode
    # entries. Effective pscompletions mode happens when:
    #   - Completion = 'pscompletions', OR
    #   - Completion = 'auto' with no NativeCommandScript (effectiveMode
    #     collapses to 'pscompletions' below).
    # If no such entries exist we skip the refresh entirely so we never
    # Import-Module PSCompletions and never trigger its nag banner.
    $needsPscUpdate = $false
    foreach ($b in $bundles) {
        foreach ($p in $b.Packages) {
            if (-not $p.CliCommands -or $p.CliCommands.Count -eq 0) { continue }
            $m = "$($p.Completion)"
            if ([string]::IsNullOrWhiteSpace($m)) { $m = 'auto' }
            if ($m -notin @('pscompletions','auto','native')) { continue }
            $hasNative = [bool]$p.HasNativeCommandScript -or [bool]$p.NativeCommandScript
            if ($m -eq 'pscompletions' -or ($m -eq 'auto' -and -not $hasNative)) {
                $needsPscUpdate = $true
                break
            }
        }
        if ($needsPscUpdate) { break }
    }
    if ($needsPscUpdate) {
        Invoke-PscCatalogUpdate
    }

    foreach ($b in $bundles) {
        foreach ($p in $b.Packages) {
            if (-not $p.CliCommands -or $p.CliCommands.Count -eq 0) { continue }
            $mode = "$($p.Completion)"
            if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'auto' }
            if ($mode -notin @('pscompletions','auto','native')) { continue }

            # Decide the effective registration mode per package:
            #   - 'native' or 'auto' + NativeCommandScript -> native (rebuild
            #     the block from NativeCommandOutputs, the text the bundle
            #     loader captured at $Packages-export time).
            #   - 'auto' without a NativeCommandScript     -> pscompletions
            #     (only safe repair path when no native source exists).
            #   - 'pscompletions'                           -> pscompletions.
            $hasNative = [bool]$p.HasNativeCommandScript -or [bool]$p.NativeCommandScript
            $effectiveMode = $mode
            if ($mode -eq 'auto') {
                $effectiveMode = if ($hasNative) { 'native' } else { 'pscompletions' }
            }

            foreach ($cli in $p.CliCommands) {
                if (-not (Get-Command $cli -ErrorAction SilentlyContinue)) {
                    $results.Add([pscustomobject]@{
                        Cli = $cli; Package = $p.Name; Bundle = $b.Bundle
                        Mode = $effectiveMode; Action = 'Skipped'; Source = 'Skipped'
                        Reason = "CLI '$cli' not on PATH."
                    })
                    continue
                }

                $blockPattern = "(?ms)^\# ScoopBucket:CliCompletion:$([regex]::Escape($cli))`:BEGIN \w+"
                $alreadyHas   = [regex]::IsMatch($existingContent, $blockPattern)
                if ($alreadyHas -and -not $Force) {
                    $results.Add([pscustomobject]@{
                        Cli = $cli; Package = $p.Name; Bundle = $b.Bundle
                        Mode = $effectiveMode; Action = 'Preserved'; Source = 'Existing'
                        Reason = 'Sentinel block already in profile; pass -Force to refresh.'
                    })
                    continue
                }

                # When the package was loaded via Get-BundlePackages
                # (PSCustomObject path) the live NativeCommandScript
                # was stripped by JSON serialization, but its pre-invoked
                # output is preserved in NativeCommandOutputs[$cli].
                # Synthesize a scriptblock that re-emits that text so
                # Register-PackageCompletion's resolver can wrap it in
                # the standard Get-Command guard. For real in-memory
                # [Package] callers we just forward the live scriptblock.
                $nativeArg = $null
                if ($effectiveMode -eq 'native') {
                    if ($p.NativeCommandScript -is [scriptblock]) {
                        $nativeArg = $p.NativeCommandScript
                    } else {
                        $preCaptured = $null
                        $no = $p.NativeCommandOutputs
                        if ($no) {
                            if ($no -is [hashtable] -and $no.ContainsKey($cli)) {
                                $preCaptured = [string]$no[$cli]
                            } elseif ($no.PSObject -and ($no.PSObject.Properties.Name -contains $cli)) {
                                $preCaptured = [string]$no.$cli
                            }
                        }
                        if ($preCaptured -and $preCaptured.Trim()) {
                            $literal = $preCaptured.Replace("'","''")
                            $nativeArg = [scriptblock]::Create("'$literal'")
                        }
                    }
                    if (-not $nativeArg) {
                        $results.Add([pscustomobject]@{
                            Cli = $cli; Package = $p.Name; Bundle = $b.Bundle
                            Mode = $effectiveMode; Action = 'Skipped'; Source = 'Skipped'
                            Reason = "No pre-captured native completion source for '$cli' (NativeCommandOutputs empty); re-run Install-Package to refresh."
                        })
                        continue
                    }
                }

                $action = "Register $effectiveMode completion block for '$cli'"
                if (-not $PSCmdlet.ShouldProcess($profileTarget, $action)) {
                    $results.Add([pscustomobject]@{
                        Cli = $cli; Package = $p.Name; Bundle = $b.Bundle
                        Mode = $effectiveMode; Action = 'WhatIf'; Source = 'Skipped'
                        Reason = '-WhatIf or -Confirm declined.'
                    })
                    continue
                }

                $registerArgs = @{
                    Cli   = $cli
                    Mode  = $effectiveMode
                }
                if ($nativeArg) { $registerArgs['NativeCommand'] = $nativeArg }
                if ($ProfilePath) { $registerArgs['ProfilePath'] = $ProfilePath }

                try {
                    $r = Register-PackageCompletion @registerArgs
                    $results.Add([pscustomobject]@{
                        Cli = $cli; Package = $p.Name; Bundle = $b.Bundle
                        Mode = $effectiveMode
                        Action = $(if ($r.Source -eq 'Skipped') { 'Skipped' } else { 'Registered' })
                        Source = $r.Source
                        Reason = $r.Reason
                    })
                } catch {
                    $results.Add([pscustomobject]@{
                        Cli = $cli; Package = $p.Name; Bundle = $b.Bundle
                        Mode = $effectiveMode; Action = 'Skipped'; Source = 'Skipped'
                        Reason = "Register-PackageCompletion threw: $($_.Exception.Message)"
                    })
                }
            }
        }
    }

    $arr = $results.ToArray()
    $byAction = $arr | Group-Object Action | ForEach-Object { "$($_.Name)=$($_.Count)" }
    if ($byAction) {
        Write-Host "Update-PackageCompletion: $($byAction -join ', ')"
    } else {
        Write-Host 'Update-PackageCompletion: no eligible CLIs found.'
    }

    return ,$arr
}
