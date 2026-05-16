function Invoke-PackageInstall {
    <#
    .SYNOPSIS
        Bundle entry-point: drive a full [Package[]] collection through
        validation, topological sort, install, post-install hooks,
        completion registration, and verification.

    .DESCRIPTION
        This is the function every migrated bundle script calls at the
        bottom of its file — once, with its full declarative `$Packages`
        collection — to actually perform the installs. It is exported
        only because Scoop runs each `bucket\<Bundle>.ps1` in a separate
        PowerShell process (via the manifest installer.script), and that
        process needs a public name to import.

        End users / interactive callers should use **Install-Package**
        instead, which targets a specific Name (or names), discovers the
        owning bundle automatically, and routes a minimal slice through
        this driver.

        Pipeline for each Package:
          1. Validate cross-field invariants ($pkg.Validate()).
          2. Filter by -Name (transitive closure) / -Skip / CISkip-in-CI.
          3. Topologically sort by DependsOn (deterministic tie-break by
             original array order).
          4. AlreadyInstalled probe (engine-specific).
          5. Install via engine dispatcher OR CustomInstallScript.
          6. Refresh `$env:Path` from registry so freshly-installed shims
             resolve.
          7. Run PostInstallScript if present.
          8. Verify install — every CliCommand resolves via Get-Command,
             or run VerifyScript when provided.
          9. Register tab-completion per Package.Completion.
         10. Record an [installed | already-installed | skipped | failed]
             entry on the summary.

        Outputs are split across PowerShell's standard streams:
          - **Success stream** — each Installed / AlreadyInstalled /
            Skipped Package is emitted via Write-Output. The function's
            return value is therefore a `[Package[]]` of successes,
            pipeline-friendly:
              `Invoke-PackageInstall ... | Where-Object Installer -eq 'winget'`.
          - **Error stream** — each Failed package emits a structured
            `ErrorRecord` (FullyQualifiedErrorId = 'PackageInstallFailed',
            TargetObject = the [Package], Exception.Message = the
            failure reason). Renders red by default; `$?` flips false;
            `-ErrorAction Stop` makes it terminating; `-ErrorVariable`
            captures it.
          - **Host / information stream** — the per-package install
            log lines and the final per-package summary table (with
            ✓ ↺ ✗ → glyphs for colorblind-safe disambiguation) are
            written via Write-Host as before. Color is now redundant
            with the glyph, not load-bearing.

    .PARAMETER Packages
        The declarative [Package[]] collection for this bundle.

    .PARAMETER Bundle
        Bundle name (e.g. 'OSBasePackages'). Appears in log lines and
        the summary record's Bundle field.

    .PARAMETER Name
        Selective install: only these packages (and their transitive
        DependsOn closure) are processed.

    .PARAMETER Skip
        Drop these packages. Packages that DependsOn-ed them log a warning.

    .PARAMETER DryRun
        Plan only — log every action without invoking engines. Named
        DryRun instead of WhatIf because SupportsShouldProcess already
        steals -WhatIf for ShouldProcess prompts.

    .PARAMETER SkipCompletion
        Don't attempt completion registration (used by tests / CI when
        the AllUsersAllHosts profile isn't writable).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([Package])]
    param(
        [Parameter(Mandatory)][object[]]$Packages,
        [Parameter(Mandatory)][string]$Bundle,
        [string[]]$Name,
        [string[]]$Skip,
        [switch]$DryRun,
        [switch]$SkipCompletion
    )

    foreach ($pkg in $Packages) {
        if ($null -eq $pkg) {
            throw "Invoke-PackageInstall: Packages array contains a null entry."
        }
        if ($pkg.GetType().Name -ne 'Package') {
            throw "Invoke-PackageInstall: every element must be a [Package]; got [$($pkg.GetType().FullName)]."
        }
        $pkg.Validate()
    }

    $sortArgs = @{ Packages = $Packages }
    if ($Name) { $sortArgs['Name'] = $Name }
    if ($Skip) { $sortArgs['Skip'] = $Skip }
    $ordered = Resolve-PackageOrder @sortArgs

    Write-Host ""
    Write-Host "=== Invoke-PackageInstall: $Bundle ($($ordered.Count) packages) ==="

    # Host-stream summary state — collected per package so the final
    # summary table can render each row with the right glyph/color. The
    # success-stream output is the [Package] itself; the error-stream
    # output is a structured ErrorRecord written below at each failure
    # site. This list is intentionally NOT returned to callers — they
    # should consume the success/error streams instead.
    $states = New-Object System.Collections.Generic.List[object]
    $isCi = [bool]$env:CI

    # If any package in this run requests PSCompletions-backed tab completion
    # (Completion='pscompletions' or 'auto'), make sure the PSCompletions
    # module is available before Register-PackageCompletion runs. Otherwise
    # Resolve-PackageCompletionSource silently returns 'Skipped' and the
    # completion never lands in the user's profile — which is exactly what
    # used to happen for `bw` (Bitwarden CLI) on a fresh box.
    if (-not $SkipCompletion -and -not $DryRun) {
        $needsPSCompletions = $ordered | Where-Object {
            $_.Completion -in @('pscompletions','auto') -and $_.CliCommands.Count -gt 0
        }
        if ($needsPSCompletions -and -not (Get-Module -ListAvailable -Name PSCompletions)) {
            try {
                Install-PSCompletionsModule -Confirm:$false
            } catch {
                Write-Warning "Invoke-PackageInstall: Install-PSCompletionsModule failed: $($_.Exception.Message). PSCompletions-backed completions will be skipped."
            }
        }
    }

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

        Write-Host ""
        Write-Host "[install] $pkg"

        try {
            if ($pkg.CustomInstallScript) {
                if ($DryRun) {
                    Write-Host "  [DryRun] CustomInstallScript"
                    $result = @{ State = 'Installed'; Reason = '(DryRun)' }
                } else {
                    # Discard any pipeline output the user's
                    # CustomInstallScript may emit — we treat it as
                    # purely side-effecting (the synthesized $result
                    # below is what we actually use). Without the
                    # [void], stray return values land on our function's
                    # success stream and pollute the [Package] output.
                    [void](& $pkg.CustomInstallScript $pkg 2>$null)
                    $result = @{ State = 'Installed'; Reason = $null }
                }
            } else {
                $result = switch ($pkg.Installer) {
                    'winget'      { Install-WingetPackage     -Package $pkg -WhatIf:$DryRun }
                    'scoop'       { Install-ScoopPackage      -Package $pkg -WhatIf:$DryRun }
                    'choco'       { Install-ChocoPackage      -Package $pkg -WhatIf:$DryRun }
                    'npmGlobal'   { Install-NpmGlobalPackage  -Package $pkg -WhatIf:$DryRun }
                    'dotnetTool'  { Install-DotnetToolPackage -Package $pkg -WhatIf:$DryRun }
                    default       { throw "Invoke-PackageInstall: unknown Installer '$($pkg.Installer)' for '$($pkg.Name)'." }
                }
            }
            $state  = $result.State
            $reason = $result.Reason
        } catch {
            $reason = "Install threw: $($_.Exception.Message)"
            $states.Add([pscustomobject]@{ Pkg = $pkg; State = 'Failed'; Reason = $reason })
            $PSCmdlet.WriteError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("$($pkg.Name): $reason"),
                    'PackageInstallFailed',
                    [System.Management.Automation.ErrorCategory]::NotInstalled,
                    $pkg))
            continue
        }

        if ($state -eq 'Failed') {
            # Engine returned a structured Failed result (e.g. winget
            # exit code mapped to State='Failed').
            $states.Add([pscustomobject]@{ Pkg = $pkg; State = 'Failed'; Reason = $reason })
            $PSCmdlet.WriteError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Exception]::new("$($pkg.Name): $reason"),
                    'PackageInstallFailed',
                    [System.Management.Automation.ErrorCategory]::NotInstalled,
                    $pkg))
            continue
        }

        if (-not $DryRun) { Update-PathFromRegistry }

        if ($pkg.PostInstallScript) {
            if ($DryRun) {
                Write-Host "  [DryRun] PostInstallScript"
            } else {
                try {
                    # PostInstallScript is purely side-effecting; discard
                    # any pipeline output so it doesn't pollute our
                    # function's success stream of [Package] objects.
                    [void](& $pkg.PostInstallScript $pkg 2>$null)
                    Update-PathFromRegistry
                } catch {
                    $reason = "PostInstallScript threw: $($_.Exception.Message)"
                    $states.Add([pscustomobject]@{ Pkg = $pkg; State = 'Failed'; Reason = $reason })
                    $PSCmdlet.WriteError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.Exception]::new("$($pkg.Name): $reason"),
                            'PackageInstallFailed',
                            [System.Management.Automation.ErrorCategory]::NotInstalled,
                            $pkg))
                    continue
                }
            }
        }

        if (-not $DryRun) {
            $verified = Test-PackageInstalled -Package $pkg
            if (-not $verified -and ($pkg.CliCommands.Count -gt 0 -or $pkg.VerifyScript)) {
                Write-Warning "  $($pkg.Name): verification failed (CliCommands not on PATH and/or VerifyScript=false)."
            }
        }

        if (-not $SkipCompletion -and -not $DryRun -and
            $pkg.Completion -ne 'none' -and $pkg.CliCommands.Count -gt 0) {
            foreach ($cli in $pkg.CliCommands) {
                $registerArgs = @{ Cli = $cli; Mode = $pkg.Completion }
                if ($pkg.NativeCommandScript) { $registerArgs['NativeCommand'] = $pkg.NativeCommandScript }
                try {
                    $null = Register-PackageCompletion @registerArgs
                } catch {
                    Write-Warning "  $($pkg.Name)/$cli completion registration failed: $($_.Exception.Message)"
                }
            }
        }

        $states.Add([pscustomobject]@{ Pkg = $pkg; State = $state; Reason = $reason })
        Write-Output $pkg
    }

    Write-Host ""
    Write-Host "=== $Bundle summary ==="
    foreach ($s in $states) {
        # Glyph carries the success/failure signal so a colorblind reader
        # (or any pipeline that strips ANSI) can still scan the table.
        # Color reinforces the glyph but is no longer load-bearing.
        $glyph = switch ($s.State) {
            'Installed'        { [char]0x2713 }   # ✓
            'AlreadyInstalled' { [char]0x21BA }   # ↺
            'Failed'           { [char]0x2717 }   # ✗
            'Skipped'          { [char]0x2192 }   # →
            default            { ' ' }
        }
        $color = switch ($s.State) {
            'Installed'        { 'Green' }
            'AlreadyInstalled' { 'DarkGreen' }
            'Failed'           { 'Red' }
            'Skipped'          { 'Yellow' }
            default            { $Host.UI.RawUI.ForegroundColor }
        }
        $line = "  {0} {1,-18} {2,-12} {3}" -f $glyph, $s.State, $s.Pkg.Installer, $s.Pkg.Name
        if ($s.Reason) { $line += "  -- $($s.Reason)" }
        Write-Host $line -ForegroundColor $color
    }
    Write-Host ""
}

function Test-PackageInstalled {
    <#
    .SYNOPSIS
        Default install verification: every Package.CliCommands entry
        resolves via Get-Command, or — when set — Package.VerifyScript
        returns truthy.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Package)

    if ($Package.VerifyScript) {
        try { return [bool](& $Package.VerifyScript $Package) }
        catch {
            Write-Verbose "VerifyScript for '$($Package.Name)' threw: $($_.Exception.Message)"
            return $false
        }
    }

    if ($Package.CliCommands.Count -eq 0) {
        return $true
    }

    foreach ($cli in $Package.CliCommands) {
        if (-not (Get-Command $cli -ErrorAction SilentlyContinue)) { return $false }
    }
    return $true
}
