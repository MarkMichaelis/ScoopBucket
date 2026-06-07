function Invoke-PackageUpdate {
    <#
    .SYNOPSIS
        Bundle driver: drive a [Package[]] collection through the per-
        installer update pipeline. Mirror of Invoke-PackageInstall.

    .DESCRIPTION
        Called by Update-Package after it resolves a user-requested Name
        (or bundle name, or '*') to a concrete [Package[]] collection.

        Pipeline for each Package:
          1. Validate cross-field invariants ($pkg.Validate()).
          2. Filter by -Name (transitive closure) / -Skip / CISkip-in-CI.
          3. Topologically sort by DependsOn (deterministic tie-break).
             Updates do NOT auto-install missing dependencies — if a
             DependsOn target isn't already on the box, the engine probe
             will simply surface NotInstalled and we move on.
          4. Dispatch to the per-engine `Update-*Package` (or the new
             optional `PostUpdateScript` for custom installs).
          5. Refresh `$env:Path` from registry.
          6. Run PostUpdateScript if present (also the *only* update hook
             available to Installer='custom').
          7. Re-register completion (CLI version bumps can introduce new
             completion definitions).

        Output streams:
          - success stream: one PackageResult per package (Updated /
            AlreadyLatest / NotInstalled / Skipped / Failed / SelfManaged /
            NoAutoUpdateSupport). A format.ps1xml view renders Status as a
            colored glyph for display; the property stays a plain string.
          - error stream: each Failed package also writes a structured
            ErrorRecord (FullyQualifiedErrorId='PackageUpdateFailed') so
            -ErrorVariable / $? / -ErrorAction Stop keep working.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([PackageResult])]
    param(
        [Parameter(Mandatory)][object[]]$Packages,
        [Parameter(Mandatory)][string]$Bundle,
        [string[]]$Name,
        [string[]]$Skip,
        [switch]$SkipCompletion,
        # Preferred alias for the standard -WhatIf preview. Bridged into
        # $WhatIfPreference below so -DryRun and -WhatIf drive one mechanism.
        [switch]$DryRun,
        # Per-package winget timeout in minutes (0 disables). Forwarded
        # to Update-WingetPackage only; other engines are unaffected.
        # Default 5 minutes; bundles can override per-package via
        # Package.UpdateTimeoutMinutes. See #269, #271.
        [int]$PackageTimeoutMinutes = 5
    )

    # The driver advertises SupportsShouldProcess, so -WhatIf flips
    # $WhatIfPreference in this scope (and is inherited by callees). Engines
    # key off -WhatIf, so thread this boolean through dispatch. The preferred
    # `-DryRun` alias bridges into the same flag for one preview mechanism.
    if ($DryRun) { $WhatIfPreference = $true }
    $isWhatIf = [bool]$WhatIfPreference

    # NOTE: cross-field validation is deliberately NOT done in a pre-loop
    # here. A single malformed declaration must fail only THAT package (as
    # a Failed result row) and let the rest of the sweep continue -- see
    # the per-package Get-PackageValidationError check inside the loop
    # below. A pre-loop throw would abort the whole bundle (and, under a
    # caller's $ErrorActionPreference='Stop', the whole `Update-Package *`
    # sweep). Resolve-PackageOrder only reads Name/DependsOn, so it is safe
    # to order before validating.

    $sortArgs = @{ Packages = $Packages }
    if ($Name) { $sortArgs['Name'] = $Name }
    if ($Skip) { $sortArgs['Skip'] = $Skip }
    $ordered = Resolve-PackageOrder @sortArgs

    Write-UpdateStatus "=== Invoke-PackageUpdate: $Bundle ($($ordered.Count) packages) ==="

    # Build the version/availability index ONCE for every non-custom installer
    # in scope (#283). It makes -WhatIf accurate (already-latest packages no
    # longer masquerade as "will update") and supplies the `from -> to` version
    # transition shown in the Details column. A flaky probe yields an empty map
    # (Resolve-PackageVersionInfo then falls back to optimistic/unknown), so it
    # never aborts the sweep.
    $nonCustomInstallers = @(
        $ordered |
            Where-Object { $_.Installer -ne 'custom' -and -not $_.CustomInstallScript } |
            ForEach-Object { [string]$_.Installer } |
            Sort-Object -Unique
    )
    $updateIndex = if ($nonCustomInstallers.Count -gt 0) {
        Get-PackageUpdateIndex -Installers $nonCustomInstallers
    } else { @{} }

    $states = New-Object System.Collections.Generic.List[object]
    $configFailures = New-Object System.Collections.Generic.List[object]
    $runStart = Get-Date
    $total  = $ordered.Count
    $idx    = 0
    $isCi   = [bool]$env:CI

    # Record a per-package outcome. Emission of the PackageResult
    # objects is deferred until after the run so interactive (uncaptured)
    # runs render a single table instead of one header-per-row mini-table
    # interleaved with each engine's live progress output. Pipeline
    # consumers are unaffected.
    $addState = {
        param($p, $st, $rs, $err, $from, $to)
        $states.Add([pscustomobject]@{ Pkg = $p; State = $st; Reason = $rs; Err = $err; From = $from; To = $to })
    }

    # Build + write the standard Failed ErrorRecord, and record the state
    # carrying that same ErrorRecord so the emitted result's .Error is
    # populated.
    $failPackage = {
        param($p, $rs)
        $errRec = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("$($p.Name): $rs"),
            'PackageUpdateFailed',
            [System.Management.Automation.ErrorCategory]::NotSpecified,
            $p)
        & $addState $p 'Failed' $rs $errRec
        $PSCmdlet.WriteError($errRec)
    }

    # ConfigScript runner: idempotent machine configuration re-applied on
    # every update for an installed package (Updated OR a no-op state like
    # AlreadyLatest), mirroring the always-run nature of the install-path
    # ConfigScript hook. Returns $true on success, $false when the script
    # threw (in which case the package has already been recorded Failed).
    $runConfigScript = {
        param($p)
        if (-not $p.ConfigScript) { return $true }
        if ($isWhatIf) {
            Write-UpdateStatus "  [WhatIf] ConfigScript ($($p.Name))"
            return $true
        }
        # Capture the ConfigScript's underlying-tool output (npm/dotnet/Write-Host)
        # into the transient channel + a recoverable buffer instead of letting it
        # flood the scrollback (#352). On a throw we flush the buffer to the host so
        # the cause stays visible, fold a tail into the Failed row, and retain the
        # output for the per-run failure log.
        $buf = New-Object System.Collections.Generic.List[string]
        try {
            Invoke-ConfigScriptCaptured -ConfigScript $p.ConfigScript -Package $p -Buffer $buf -Activity 'Update-Package'
            return $true
        } catch {
            $reason = "ConfigScript threw: $($_.Exception.Message)$(Get-CapturedOutputTail (($buf) -join [Environment]::NewLine))"
            & $failPackage $p $reason
            Out-CapturedFailure -Name $p.Name -Lines $buf
            $configFailures.Add([pscustomobject]@{
                    Name   = $p.Name
                    Reason = "ConfigScript threw: $($_.Exception.Message)"
                    Output = ($buf -join [Environment]::NewLine)
                })
            return $false
        }
    }

    try {
    foreach ($pkg in $ordered) {
        $state  = 'Pending'
        $reason = $null
        $from   = $null
        $to     = $null
        $idx++
        $pct = if ($total -gt 0) { [int](($idx - 1) / $total * 100) } else { 0 }

        # Validate cross-field invariants per package. A malformed
        # declaration (e.g. a custom package whose CustomInstallScript was
        # stripped by the metadata round-trip) becomes a single Failed row
        # and the sweep continues to the next package.
        $declErr = Get-PackageValidationError $pkg
        if ($declErr) {
            & $failPackage $pkg "Invalid package declaration: $declErr"
            continue
        }

        if ($pkg.CISkip -and $isCi) {
            $state  = 'Skipped'
            $reason = "CISkip: $($pkg.CISkip)"
            Write-UpdateStatus "[skip] $($pkg.Name) -- $reason" -PercentComplete $pct
            & $addState $pkg $state $reason $null
            continue
        }

        # Updates don't auto-install missing dependencies. If a DependsOn
        # target isn't in the ordered set (it would only be missing if it
        # was filtered out by -Skip or wasn't requested), warn but do not
        # block — the engine probe will catch genuine missing prereqs.
        if ($pkg.DependsOn) {
            foreach ($dep in $pkg.DependsOn) {
                if (-not ($ordered | Where-Object Name -eq $dep)) {
                    Write-Warning "  $($pkg.Name): DependsOn '$dep' not in update set; update will not install missing prerequisites."
                }
            }
        }

        Write-UpdateStatus "Updating $($pkg.Name) ($($pkg.Installer))..." -PercentComplete $pct

        try {
            if ($pkg.Installer -eq 'custom' -or $pkg.CustomInstallScript) {
                # Custom installs have no generic engine upgrade path.
                # UpdateMode declares how (or whether) to update them. Each
                # arm produces a uniform $result; terminal no-op states
                # (SelfManaged / NoAutoUpdateSupport) are routed through the
                # short-circuit list below (continue inside a PowerShell
                # switch would only exit the switch, not the foreach).
                switch ($pkg.UpdateMode) {
                    'SelfManaged' {
                        # Updates itself / managed externally -- intentional no-op.
                        $result = @{ State = 'SelfManaged'; Reason = $null }
                    }
                    'NoAutoUpdateSupport' {
                        # Explicitly no mechanism this tool can drive.
                        $result = @{ State = 'NoAutoUpdateSupport'; Reason = $null }
                    }
                    'Reinstall' {
                        if (-not $pkg.CustomInstallScript) {
                            # Metadata-only fallback path lost the scriptblock.
                            $result = @{ State = 'NoAutoUpdateSupport'; Reason = 'Reinstall requested but this package was loaded without its CustomInstallScript (metadata-only); Reinstall unavailable.' }
                        } elseif ($isWhatIf) {
                            $result = @{ State = 'Updated'; Reason = '(Reinstall) (WhatIf)' }
                        } else {
                            [void](& $pkg.CustomInstallScript $pkg)
                            if ($pkg.VerifyScript) {
                                $ok = & $pkg.VerifyScript $pkg
                                if (-not $ok) {
                                    throw 'VerifyScript reported the package is not present after reinstall.'
                                }
                            }
                            $result = @{ State = 'Updated'; Reason = '(Reinstall)' }
                        }
                    }
                    default {
                        # 'Auto': PostUpdateScript is the only hook; without
                        # it there is genuinely nothing to drive.
                        if (-not $pkg.PostUpdateScript) {
                            $result = @{ State = 'NoAutoUpdateSupport'; Reason = $null }
                        } else {
                            $result = @{ State = 'Updated'; Reason = '(PostUpdateScript-only)' }
                        }
                    }
                }
            } else {
                # Probe this package's installed/available versions from the
                # pre-built index (#283). Drives accurate -WhatIf and the
                # `from -> to` Details annotation.
                $verInfo = Resolve-PackageVersionInfo -Package $pkg -Index $updateIndex
                if ($verInfo.Installed) { $from = $verInfo.Installed }

                if ($isWhatIf) {
                    # Dry run: decide the outcome from the probe instead of
                    # invoking the engine. Already-latest packages now report
                    # AlreadyLatest (=) rather than a misleading Updated (+).
                    if ($verInfo.Present -eq $false) {
                        $result = @{ State = 'NotInstalled'; Reason = $null }
                    } elseif ($verInfo.UpdateAvailable -eq $true) {
                        $to     = $verInfo.Available
                        $result = @{ State = 'Updated'; Reason = '(WhatIf)' }
                    } elseif ($verInfo.UpdateAvailable -eq $false) {
                        $to     = $from
                        $result = @{ State = 'AlreadyLatest'; Reason = $null }
                    } else {
                        # Availability unknown (dotnetTool, or the engine wasn't
                        # probed): can't promise a no-op, so plan the update but
                        # say so.
                        $result = @{ State = 'Updated'; Reason = '(WhatIf, version unknown)' }
                    }
                } else {
                    $result = switch ($pkg.Installer) {
                        'winget'      { Update-WingetPackage     -Package $pkg -WhatIf:$isWhatIf -TimeoutMinutes $PackageTimeoutMinutes }
                        'scoop'       { Update-ScoopPackage      -Package $pkg -WhatIf:$isWhatIf }
                        'choco'       { Update-ChocoPackage      -Package $pkg -WhatIf:$isWhatIf }
                        'npmGlobal'   { Update-NpmGlobalPackage  -Package $pkg -WhatIf:$isWhatIf }
                        'dotnetTool'  { Update-DotnetToolPackage -Package $pkg -WhatIf:$isWhatIf }
                        default       { throw "Invoke-PackageUpdate: unknown Installer '$($pkg.Installer)' for '$($pkg.Name)'." }
                    }
                    # Annotate the version transition from the pre-update probe.
                    # On a real upgrade the index's Available column is the
                    # version we just moved TO; AlreadyLatest pins to == from.
                    if ($result.State -eq 'Updated' -and $verInfo.Available) {
                        $to = $verInfo.Available
                    } elseif ($result.State -eq 'AlreadyLatest') {
                        $to = $from
                    }
                }
            }
            $state  = $result.State
            $reason = $result.Reason
        } catch {
            & $failPackage $pkg "Update threw: $($_.Exception.Message)"
            continue
        }

        if ($state -eq 'Failed') {
            & $failPackage $pkg $reason
            continue
        }

        # NotInstalled / Skipped: the package is not present / not processed,
        # so there is nothing to configure -- no ConfigScript, no hooks.
        if ($state -in @('NotInstalled', 'Skipped')) {
            & $addState $pkg $state $reason $null $from $to
            continue
        }

        # AlreadyLatest / SelfManaged / NoAutoUpdateSupport: the package IS
        # installed but there was no version bump, so PATH refresh,
        # PostUpdateScript, and completion re-register are intentionally
        # skipped. ConfigScript STILL runs -- idempotent config is re-applied
        # on every update regardless of whether a new version was fetched.
        if ($state -in @('AlreadyLatest', 'SelfManaged', 'NoAutoUpdateSupport')) {
            if (-not (& $runConfigScript $pkg)) { continue }
            & $addState $pkg $state $reason $null $from $to
            continue
        }

        if (-not $isWhatIf) { Update-PathFromRegistry }

        if ($pkg.PostUpdateScript) {
            if ($isWhatIf) {
                Write-UpdateStatus "  [WhatIf] PostUpdateScript ($($pkg.Name))" -PercentComplete $pct
            } else {
                try {
                    [void](& $pkg.PostUpdateScript $pkg 2>$null)
                    Update-PathFromRegistry
                } catch {
                    & $failPackage $pkg "PostUpdateScript threw: $($_.Exception.Message)"
                    continue
                }
            }
        }

        # Idempotent config after a real upgrade, before completion re-register.
        if (-not (& $runConfigScript $pkg)) { continue }

        # Re-register completion only when we actually upgraded — note
        # the AlreadyLatest / NotInstalled paths already short-circuited
        # above, so reaching here means $state -eq 'Updated'.
        if ($state -eq 'Updated' -and -not $SkipCompletion -and -not $isWhatIf -and
            $pkg.Completion -ne 'none' -and $pkg.CliCommands.Count -gt 0) {
            foreach ($cli in $pkg.CliCommands) {
                $registerArgs = @{ Cli = $cli; Mode = $pkg.Completion }
                if ($pkg.NativeCommandScript) { $registerArgs['NativeCommand'] = $pkg.NativeCommandScript }
                try {
                    $null = Register-PackageCompletion @registerArgs
                } catch {
                    Write-Warning "  $($pkg.Name)/$cli completion re-registration failed: $($_.Exception.Message)"
                }
            }
        }

        & $addState $pkg $state $reason $null $from $to
    }
    }
    finally {
        # Tear down the transient status bar / progress line before emitting results
        # so the two don't fight over the host's rendering. In a finally so an aborted
        # or throwing run never leaves the terminal with a stuck VT scroll region.
        Write-UpdateStatus -Completed
    }

    # When any package's ConfigScript failed, persist its full captured output to a
    # per-run log so the cause survives the transient pane (#352).
    if ($configFailures.Count -gt 0 -and -not $isWhatIf) {
        try {
            $logName = Get-FailureLogFileName -Verb 'Update' -Timestamp $runStart
            $logPath = Get-FailureLogPath -FileName $logName -PreferredDirectory (Get-Location).Path -FallbackDirectory $env:TEMP
            $written = Write-FailureLog -Path $logPath -Verb 'Update' -Failures $configFailures.ToArray()
            Write-Host "Update-Package: wrote failure log to $written" -ForegroundColor Yellow
        } catch {
            Write-Warning "Update-Package: could not write failure log: $($_.Exception.Message)"
        }
    }

    # Emit one PackageResult per package on the success stream. The
    # format.ps1xml view renders Status as a colored glyph for interactive
    # display; piped/exported consumers see the plain Status string and the
    # structured .Error ErrorRecord on failures.
    foreach ($s in $states) {
        [PackageResult]@{
            Operation   = 'Update'
            Status      = $s.State
            Name        = $s.Pkg.Name
            Installer   = $s.Pkg.Installer
            Scope       = $s.Pkg.Scope
            Id          = $s.Pkg.Id
            Bundle      = $Bundle
            VersionFrom = $s.From
            VersionTo   = $s.To
            Reason      = $s.Reason
            Error       = $s.Err
        }
    }
}
