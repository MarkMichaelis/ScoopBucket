function Update-PackageCompletion {
    <#
    .SYNOPSIS
        Repair / refresh tab-completion sentinel blocks for every
        Package in the bucket whose CliCommand is on PATH but has no
        block in $PROFILE.AllUsersAllHosts.

    .DESCRIPTION
        Solves the "I have the CLI installed but `<cli> <Tab>` only
        completes file names" recovery scenario: after restoring a dev
        machine, the CLIs are back on PATH but $PROFILE.AllUsersAllHosts
        was not part of the backup, so no sentinel blocks exist. For
        native-completion CLIs (`gh`, `rg`, …) this used to require
        running the original Install-Package per bundle.

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

        Issue #241 removed the PSCompletions integration: any package
        declared Completion='pscompletions' (none remain in this bucket)
        now resolves to Source='Skipped' with a remediation Reason
        instead of being routed through `psc add`/`psc list`. The
        'pscompletions' Completion value is preserved as a recognized
        package class for schema compatibility, but no longer
        contributes a runtime completion block. The PSCompletions
        bundle itself was deleted in #241, so the previously-documented
        "Install-Package PSCompletions heals already-installed CLIs"
        flow no longer applies.

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
        | Skipped | WhatIf), Source (Native | Existing | Skipped |
        WhatIf — 'Existing' accompanies Action='Preserved', 'WhatIf'
        accompanies a -WhatIf preview row; PSCompletions was removed in
        #241), and Reason fields. WhatIf preview rows carry an empty
        Reason — the Action column already says 'WhatIf' — and do NOT
        emit the built-in "What if:" host line (the returned summary
        table is the single source of truth).

        The Mode column reports how the completion block is sourced (#289):
          native  — the block is produced live from the tool's own
                    completion engine (dotnet/rg/warp/todoist), declared
                    via the package's NativeCompletionKind='native'.
          curated — a hand-maintained subcommand/flag list shipped by this
                    bucket (the default for native registrations whose
                    NativeCompletionKind is unset).
          pscompletions — legacy class retained for schema compatibility;
                    no packages resolve to it after #241.
        Both native and curated use the same Register-ArgumentCompleter
        -Native wiring; Mode describes the SOURCE, not the mechanism.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject[]])]
    param(
        [string]$BucketPath,
        [switch]$Force,
        [string]$ProfilePath,
        [switch]$IncludeUnchanged
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

            # Reporting label for the Mode column. A native registration is
            # either 'native' (the block is sourced live from the tool's own
            # completion engine -- dotnet/rg/warp/todoist) or 'curated' (a
            # hand-maintained list this bucket ships because the tool has no
            # PowerShell-native completion). The package declares which via
            # NativeCompletionKind; an unset kind under-claims as 'curated'.
            # The registration mechanism is identical for both
            # (Register-ArgumentCompleter -Native), so $effectiveMode -- the
            # value handed to Register-PackageCompletion below -- stays
            # 'native'; only the displayed Mode differs.
            $displayMode = $effectiveMode
            if ($effectiveMode -eq 'native') {
                $displayMode = if ("$($p.NativeCompletionKind)" -eq 'native') { 'native' } else { 'curated' }
            }

            foreach ($cli in $p.CliCommands) {
                if (-not (Get-Command $cli -ErrorAction SilentlyContinue)) {
                    $results.Add([pscustomobject]@{
                        Cli = $cli; Package = $p.Name; Bundle = $b.Bundle
                        Mode = $displayMode; Action = 'Skipped'; Source = 'Skipped'
                        Reason = "CLI '$cli' not on PATH."
                    })
                    continue
                }

                $blockPattern = "(?ms)^\# ScoopBucket:CliCompletion:$([regex]::Escape($cli))`:BEGIN \w+"
                $alreadyHas   = [regex]::IsMatch($existingContent, $blockPattern)
                if ($alreadyHas -and -not $Force) {
                    $results.Add([pscustomobject]@{
                        Cli = $cli; Package = $p.Name; Bundle = $b.Bundle
                        Mode = $displayMode; Action = 'Preserved'; Source = 'Existing'
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
                            Mode = $displayMode; Action = 'Skipped'; Source = 'Skipped'
                            Reason = "No pre-captured native completion source for '$cli' (NativeCommandOutputs empty); re-run Install-Package to refresh."
                        })
                        continue
                    }
                }

                $action = "Register $effectiveMode completion block for '$cli'"

                # -WhatIf preview: record the would-be row WITHOUT calling
                # $PSCmdlet.ShouldProcess. ShouldProcess's built-in
                # "What if: Performing the operation ..." line is written
                # straight to the host (it bypasses every output stream, so
                # it can't be redirected) and merely duplicates this row in
                # the summary table -- which is the single source of truth.
                # The Action column already says 'WhatIf', so the Reason is
                # left empty rather than a redundant '(would register)'.
                if ($WhatIfPreference) {
                    $results.Add([pscustomobject]@{
                        Cli = $cli; Package = $p.Name; Bundle = $b.Bundle
                        Mode = $displayMode; Action = 'WhatIf'; Source = 'WhatIf'
                        Reason = ''
                    })
                    continue
                }

                # Real run (or -Confirm). ShouldProcess still gates the write
                # and drives the -Confirm prompt; a declined prompt is a
                # Skipped row, not a registration.
                if (-not $PSCmdlet.ShouldProcess($profileTarget, $action)) {
                    $results.Add([pscustomobject]@{
                        Cli = $cli; Package = $p.Name; Bundle = $b.Bundle
                        Mode = $displayMode; Action = 'Skipped'; Source = 'Skipped'
                        Reason = 'Declined at the confirmation prompt.'
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
                        Mode = $displayMode
                        Action = $(if ($r.Source -eq 'Skipped') { 'Skipped' } else { 'Registered' })
                        Source = $r.Source
                        Reason = $r.Reason
                    })
                } catch {
                    $results.Add([pscustomobject]@{
                        Cli = $cli; Package = $p.Name; Bundle = $b.Bundle
                        Mode = $displayMode; Action = 'Skipped'; Source = 'Skipped'
                        Reason = "Register-PackageCompletion threw: $($_.Exception.Message)"
                    })
                }
            }
        }
    }

    $arr = $results.ToArray()

    # Tag every row with a type name so the format view can render a tidy,
    # consistent column set (mirrors the #283 PackageResult table).
    foreach ($row in $arr) {
        if ($row -and -not ($row.PSObject.TypeNames -contains 'MarkMichaelis.ScoopBucket.CompletionResult')) {
            $row.PSObject.TypeNames.Insert(0, 'MarkMichaelis.ScoopBucket.CompletionResult')
        }
    }

    # The returned row objects ARE the output -- a Write-Host tally of the
    # VISIBLE rows would duplicate them (the anti-pattern removed from the
    # package tables in #276). Mirror a one-line tally to the transient verbose
    # stream only.
    $byAction = $arr | Group-Object Action | ForEach-Object { "$($_.Name)=$($_.Count)" }
    if ($byAction) {
        Write-Verbose "Update-PackageCompletion: $($byAction -join ', ')"
    } else {
        Write-Verbose 'Update-PackageCompletion: no eligible CLIs found.'
    }

    if ($IncludeUnchanged) {
        return , $arr
    }

    # Changed-only view (#285): show only rows that represent an action --
    # Registered (we wrote a block) or WhatIf (we would). Preserved (already in
    # the profile) and Skipped (CLI absent / no native source) are the quiet
    # majority; summarize their counts on a host-only line that, unlike the
    # removed #276 tally, never duplicates a visible row.
    $changed = @('Registered', 'WhatIf')
    $shown = New-Object System.Collections.Generic.List[object]
    $suppressed = @{}
    foreach ($row in $arr) {
        if ($changed -contains $row.Action) {
            [void]$shown.Add($row)
            continue
        }
        $label = "$($row.Action)".ToLowerInvariant()
        if ($suppressed.ContainsKey($label)) { $suppressed[$label]++ } else { $suppressed[$label] = 1 }
    }

    if ($suppressed.Count -gt 0) {
        $parts = $suppressed.GetEnumerator() |
            Sort-Object @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key'; Descending = $false } |
            ForEach-Object { "$($_.Value) $($_.Key)" }
        Write-Host ("Hidden: {0}   (-IncludeUnchanged to show all)" -f ($parts -join ', ')) -ForegroundColor DarkGray
        Write-Host ''
    }

    return , $shown.ToArray()
}
