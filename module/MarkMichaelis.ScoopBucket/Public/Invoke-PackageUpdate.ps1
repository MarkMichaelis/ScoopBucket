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
        # Per-package winget timeout in minutes (0 disables). Forwarded
        # to Update-WingetPackage only; other engines are unaffected.
        # Default 5 minutes; bundles can override per-package via
        # Package.UpdateTimeoutMinutes. See #269, #271.
        [int]$PackageTimeoutMinutes = 5
    )

    # The driver advertises SupportsShouldProcess, so -WhatIf flips
    # $WhatIfPreference in this scope (and is inherited by callees). Engines
    # key off -WhatIf, so thread this boolean through dispatch.
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

    $states = New-Object System.Collections.Generic.List[object]
    $total  = $ordered.Count
    $idx    = 0
    $isCi   = [bool]$env:CI

    # Record a per-package outcome. Emission of the PackageResult
    # objects is deferred until after the run so interactive (uncaptured)
    # runs render a single table instead of one header-per-row mini-table
    # interleaved with each engine's live progress output. Pipeline
    # consumers are unaffected.
    $addState = {
        param($p, $st, $rs, $err)
        $states.Add([pscustomobject]@{ Pkg = $p; State = $st; Reason = $rs; Err = $err })
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

    foreach ($pkg in $ordered) {
        $state  = 'Pending'
        $reason = $null
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
                            $result = @{ State = 'Updated'; Reason = '(WhatIf)' }
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
                $result = switch ($pkg.Installer) {
                    'winget'      { Update-WingetPackage     -Package $pkg -WhatIf:$isWhatIf -TimeoutMinutes $PackageTimeoutMinutes }
                    'scoop'       { Update-ScoopPackage      -Package $pkg -WhatIf:$isWhatIf }
                    'choco'       { Update-ChocoPackage      -Package $pkg -WhatIf:$isWhatIf }
                    'npmGlobal'   { Update-NpmGlobalPackage  -Package $pkg -WhatIf:$isWhatIf }
                    'dotnetTool'  { Update-DotnetToolPackage -Package $pkg -WhatIf:$isWhatIf }
                    default       { throw "Invoke-PackageUpdate: unknown Installer '$($pkg.Installer)' for '$($pkg.Name)'." }
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

        # NotInstalled / Skipped / AlreadyLatest / SelfManaged /
        # NoAutoUpdateSupport short-circuit: no PATH refresh, no PostUpdate
        # hook, no completion re-register. The registered completer is by
        # definition still current for AlreadyLatest, and running
        # PostUpdateScript on a no-op upgrade would surprise bundle authors
        # who only intend the hook to fire after a real version bump.
        if ($state -in @('NotInstalled', 'Skipped', 'AlreadyLatest', 'SelfManaged', 'NoAutoUpdateSupport')) {
            & $addState $pkg $state $reason $null
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

        & $addState $pkg $state $reason $null
    }

    # Tear down the transient progress line before emitting results so the
    # two don't fight over the host's rendering.
    Write-UpdateStatus -Completed

    # Emit one PackageResult per package on the success stream. The
    # format.ps1xml view renders Status as a colored glyph for interactive
    # display; piped/exported consumers see the plain Status string and the
    # structured .Error ErrorRecord on failures.
    foreach ($s in $states) {
        [PackageResult]@{
            Operation = 'Update'
            Status    = $s.State
            Name      = $s.Pkg.Name
            Installer = $s.Pkg.Installer
            Scope     = $s.Pkg.Scope
            Id        = $s.Pkg.Id
            Bundle    = $Bundle
            Reason    = $s.Reason
            Error     = $s.Err
        }
    }
}
