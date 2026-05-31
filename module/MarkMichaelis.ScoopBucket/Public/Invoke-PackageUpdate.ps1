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

        Output streams mirror Invoke-PackageInstall:
          - success stream: each Updated / AlreadyLatest / NotInstalled /
            Skipped Package emits via Write-Output ([Package]).
          - error stream: each Failed package writes a structured
            ErrorRecord (FullyQualifiedErrorId='PackageUpdateFailed').
          - host stream: per-package log lines and the per-bundle summary
            table (✓ Updated, ↺ AlreadyLatest, ✗ Failed, → Skipped/NotInstalled).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([Package])]
    param(
        [Parameter(Mandatory)][object[]]$Packages,
        [Parameter(Mandatory)][string]$Bundle,
        [string[]]$Name,
        [string[]]$Skip,
        [switch]$DryRun,
        [switch]$SkipCompletion,
        # Per-package winget timeout in minutes (0 disables). Forwarded
        # to Update-WingetPackage only; other engines are unaffected.
        # Default 5 minutes; bundles can override per-package via
        # Package.UpdateTimeoutMinutes. See #269, #271.
        [int]$PackageTimeoutMinutes = 5
    )

    # Fold -WhatIf into -DryRun. The driver advertises
    # SupportsShouldProcess; without this, `Invoke-PackageUpdate -WhatIf`
    # would not propagate the safety contract down to the engines
    # (which key off $DryRun, mapped to engine -WhatIf at dispatch time).
    if ($WhatIfPreference -and -not $DryRun) { $DryRun = $true }

    foreach ($pkg in $Packages) {
        if ($null -eq $pkg) {
            throw "Invoke-PackageUpdate: Packages array contains a null entry."
        }
        if ($pkg.GetType().Name -ne 'Package') {
            throw "Invoke-PackageUpdate: every element must be a [Package]; got [$($pkg.GetType().FullName)]."
        }
        $pkg.Validate()
    }

    $sortArgs = @{ Packages = $Packages }
    if ($Name) { $sortArgs['Name'] = $Name }
    if ($Skip) { $sortArgs['Skip'] = $Skip }
    $ordered = Resolve-PackageOrder @sortArgs

    Write-Host ""
    Write-Host "=== Invoke-PackageUpdate: $Bundle ($($ordered.Count) packages) ==="

    $states = New-Object System.Collections.Generic.List[object]
    $isCi = [bool]$env:CI

    foreach ($pkg in $ordered) {
        $state  = 'Pending'
        $reason = $null

        if ($pkg.CISkip -and $isCi) {
            $state  = 'Skipped'
            $reason = "CISkip: $($pkg.CISkip)"
            Write-Host "[skip] $($pkg.Name) -- $reason"
            $states.Add([pscustomobject]@{ Pkg = $pkg; State = $state; Reason = $reason })
            Write-Output $pkg
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

        Write-Host ""
        Write-Host "[update] $pkg"

        try {
            if ($pkg.Installer -eq 'custom' -or $pkg.CustomInstallScript) {
                # Custom installs have no generic engine upgrade path.
                # The only hook is PostUpdateScript; without it we skip.
                if (-not $pkg.PostUpdateScript) {
                    $state  = 'Skipped'
                    $reason = 'No update path for CustomInstallScript packages (consider adding PostUpdateScript).'
                    Write-Host "  $reason"
                    $states.Add([pscustomobject]@{ Pkg = $pkg; State = $state; Reason = $reason })
                    Write-Output $pkg
                    continue
                }
                $result = @{ State = 'Updated'; Reason = '(PostUpdateScript-only)' }
            } else {
                $result = switch ($pkg.Installer) {
                    'winget'      { Update-WingetPackage     -Package $pkg -WhatIf:$DryRun -TimeoutMinutes $PackageTimeoutMinutes }
                    'scoop'       { Update-ScoopPackage      -Package $pkg -WhatIf:$DryRun }
                    'choco'       { Update-ChocoPackage      -Package $pkg -WhatIf:$DryRun }
                    'npmGlobal'   { Update-NpmGlobalPackage  -Package $pkg -WhatIf:$DryRun }
                    'dotnetTool'  { Update-DotnetToolPackage -Package $pkg -WhatIf:$DryRun }
                    default       { throw "Invoke-PackageUpdate: unknown Installer '$($pkg.Installer)' for '$($pkg.Name)'." }
                }
            }
            $state  = $result.State
            $reason = $result.Reason
        } catch {
            $reason = "Update threw: $($_.Exception.Message)"
            $states.Add([pscustomobject]@{ Pkg = $pkg; State = 'Failed'; Reason = $reason })
            $PSCmdlet.WriteError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("$($pkg.Name): $reason"),
                    'PackageUpdateFailed',
                    [System.Management.Automation.ErrorCategory]::NotSpecified,
                    $pkg))
            continue
        }

        if ($state -eq 'Failed') {
            $states.Add([pscustomobject]@{ Pkg = $pkg; State = 'Failed'; Reason = $reason })
            $PSCmdlet.WriteError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("$($pkg.Name): $reason"),
                    'PackageUpdateFailed',
                    [System.Management.Automation.ErrorCategory]::NotSpecified,
                    $pkg))
            continue
        }

        # NotInstalled / Skipped / AlreadyLatest short-circuit: no PATH
        # refresh, no PostUpdate hook, no completion re-register. The
        # registered completer is by definition still current for
        # AlreadyLatest, and running PostUpdateScript on a no-op upgrade
        # would surprise bundle authors who only intend the hook to fire
        # after a real version bump.
        if ($state -in @('NotInstalled', 'Skipped', 'AlreadyLatest')) {
            $states.Add([pscustomobject]@{ Pkg = $pkg; State = $state; Reason = $reason })
            Write-Output $pkg
            continue
        }

        if (-not $DryRun) { Update-PathFromRegistry }

        if ($pkg.PostUpdateScript) {
            if ($DryRun) {
                Write-Host "  [DryRun] PostUpdateScript"
            } else {
                try {
                    [void](& $pkg.PostUpdateScript $pkg 2>$null)
                    Update-PathFromRegistry
                } catch {
                    $reason = "PostUpdateScript threw: $($_.Exception.Message)"
                    $states.Add([pscustomobject]@{ Pkg = $pkg; State = 'Failed'; Reason = $reason })
                    $PSCmdlet.WriteError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.Exception]::new("$($pkg.Name): $reason"),
                            'PackageUpdateFailed',
                            [System.Management.Automation.ErrorCategory]::NotSpecified,
                            $pkg))
                    continue
                }
            }
        }

        # Re-register completion only when we actually upgraded — note
        # the AlreadyLatest / NotInstalled paths already short-circuited
        # above, so reaching here means $state -eq 'Updated'.
        if ($state -eq 'Updated' -and -not $SkipCompletion -and -not $DryRun -and
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

        $states.Add([pscustomobject]@{ Pkg = $pkg; State = $state; Reason = $reason })
        Write-Output $pkg
    }

    Write-Host ""
    Write-Host "=== $Bundle update summary ==="
    foreach ($s in $states) {
        $glyph = switch ($s.State) {
            'Updated'       { [char]0x2713 }   # ✓
            'AlreadyLatest' { [char]0x21BA }   # ↺
            'Failed'        { [char]0x2717 }   # ✗
            'Skipped'       { [char]0x2192 }   # →
            'NotInstalled'  { [char]0x2192 }   # →
            default         { ' ' }
        }
        $color = switch ($s.State) {
            'Updated'       { 'Green' }
            'AlreadyLatest' { 'DarkGreen' }
            'Failed'        { 'Red' }
            'Skipped'       { 'Yellow' }
            'NotInstalled'  { 'Yellow' }
            default         { $Host.UI.RawUI.ForegroundColor }
        }
        $line = "  {0} {1,-14} {2,-12} {3}" -f $glyph, $s.State, $s.Pkg.Installer, $s.Pkg.Name
        if ($s.Reason) { $line += "  -- $($s.Reason)" }
        Write-Host $line -ForegroundColor $color
    }
    Write-Host ""
}
