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

        Outputs (mirror of Invoke-PackageUpdate):
          - **Success stream** — one [PackageResult] per package
            (Operation='Install'; Status Installed / AlreadyInstalled /
            Skipped / Failed), emitted after the run so an interactive
            caller sees a single table rendered by the format.ps1xml view.
            The Status stays a plain string for filtering / export:
              `Install-Package Foo | Where-Object Status -eq 'Failed'`.
          - **Error stream** — each Failed package emits a structured
            `ErrorRecord` (FullyQualifiedErrorId = 'PackageInstallFailed',
            TargetObject = the [Package], Exception.Message = the
            failure reason). Renders red by default; `$?` flips false;
            `-ErrorAction Stop` makes it terminating; `-ErrorVariable`
            captures it.
          - **Progress / verbose stream** — per-package install log lines
            are routed through Write-UpdateStatus (transient progress,
            mirrored to -Verbose), quiet by default. No Write-Host table.

    .PARAMETER Packages
        The declarative [Package[]] collection for this bundle.

    .PARAMETER Bundle
        Bundle name (e.g. 'OSBasePackages'). Appears in log lines and
        the result record's Bundle field.

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
    [OutputType([PackageResult])]
    param(
        [Parameter(Mandatory)][object[]]$Packages,
        [Parameter(Mandatory)][string]$Bundle,
        [string[]]$Name,
        [string[]]$Skip,
        [switch]$DryRun,
        [switch]$SkipCompletion
    )

    # Cross-field validation is intentionally NOT done in a pre-loop. A
    # single malformed declaration must fail only THAT package (as a Failed
    # row) and let the remaining installs proceed -- mirror of
    # Invoke-PackageUpdate. See the per-package Get-PackageValidationError
    # check inside the loop below. Resolve-PackageOrder only reads
    # Name/DependsOn, so ordering before validating is safe.

    $sortArgs = @{ Packages = $Packages }
    if ($Name) { $sortArgs['Name'] = $Name }
    if ($Skip) { $sortArgs['Skip'] = $Skip }
    $ordered = Resolve-PackageOrder @sortArgs

    Write-UpdateStatus -Activity 'Install-Package' "Invoke-PackageInstall: $Bundle ($($ordered.Count) packages)..."

    # Per-package outcome records. Emission of the [PackageResult] objects is
    # deferred until after the loop so an interactive run renders a single
    # table; failures additionally go to the error stream at each failure site.
    $states = New-Object System.Collections.Generic.List[object]
    $isCi = [bool]$env:CI

    $addState = {
        param($p, $st, $rs, $err)
        $states.Add([pscustomobject]@{ Pkg = $p; State = $st; Reason = $rs; Err = $err })
    }

    # Build + write the standard Failed ErrorRecord, and record the state
    # carrying that same ErrorRecord so the emitted result's .Error is
    # populated. A failed package never stops the sweep — the caller still
    # gets a Failed row plus a structured ErrorRecord on the error stream.
    $failPackage = {
        param($p, $rs, $name)
        $pkgName = if ($name) { $name } else { $p.Name }
        $errRec = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("${pkgName}: $rs"),
            'PackageInstallFailed',
            [System.Management.Automation.ErrorCategory]::NotInstalled,
            $p)
        & $addState $p 'Failed' $rs $errRec
        $PSCmdlet.WriteError($errRec)
    }

    foreach ($pkg in $ordered) {
        $state  = 'Pending'
        $reason = $null

        # Validate per package so a malformed declaration fails just this
        # one install and the batch continues (parity with the update path).
        $declErr = Get-PackageValidationError $pkg
        if ($declErr) {
            $reason = "Invalid package declaration: $declErr"
            $pkgName = if ($null -ne $pkg -and $pkg.PSObject.Properties.Name -contains 'Name') { $pkg.Name } else { '<unknown>' }
            & $failPackage $pkg $reason $pkgName
            continue
        }

        if ($pkg.CISkip -and $isCi) {
            $state  = 'Skipped'
            $reason = "CISkip: $($pkg.CISkip)"
            Write-UpdateStatus -Activity 'Install-Package' "[skip] $($pkg.Name) -- $reason"
            & $addState $pkg $state $reason $null
            continue
        }

        Write-UpdateStatus -Activity 'Install-Package' "[install] $pkg"

        try {
            if ($pkg.CustomInstallScript) {
                if ($DryRun) {
                    Write-UpdateStatus -Activity 'Install-Package' "  [DryRun] CustomInstallScript"
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
            & $failPackage $pkg $reason
            continue
        }

        if ($state -eq 'Failed') {
            # Engine returned a structured Failed result (e.g. winget
            # exit code mapped to State='Failed').
            & $failPackage $pkg $reason
            continue
        }

        if (-not $DryRun) { Update-PathFromRegistry }

        if ($pkg.PostInstallScript) {
            if ($DryRun) {
                Write-UpdateStatus -Activity 'Install-Package' "  [DryRun] PostInstallScript"
            } else {
                try {
                    # PostInstallScript is purely side-effecting; discard
                    # any pipeline output so it doesn't pollute our
                    # function's success stream of [Package] objects.
                    [void](& $pkg.PostInstallScript $pkg 2>$null)
                    Update-PathFromRegistry
                } catch {
                    $reason = "PostInstallScript threw: $($_.Exception.Message)"
                    & $failPackage $pkg $reason
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
                # Prefer the loader's pre-captured native completer text
                # (NativeCommandOutputs[$cli]) when present -- avoids
                # re-running the CLI's `<cli> completions powershell`
                # subprocess inside Register-PackageCompletion (#212).
                if ($pkg.PSObject.Properties.Name -contains 'NativeCommandOutputs' -and $pkg.NativeCommandOutputs) {
                    $no = $pkg.NativeCommandOutputs
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
                    Write-Warning "  $($pkg.Name)/$cli completion registration failed: $($_.Exception.Message)"
                }
            }
        }

        & $addState $pkg $state $reason $null
    }

    # Tear down the transient progress line before emitting results so the
    # two don't fight over the host's rendering.
    Write-UpdateStatus -Activity 'Install-Package' -Completed

    # Emit one PackageResult per package on the success stream. The
    # format.ps1xml view renders Status as a colored glyph for interactive
    # display; piped/exported consumers see the plain Status string and the
    # structured .Error ErrorRecord on failures.
    foreach ($s in $states) {
        [PackageResult]@{
            Operation = 'Install'
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
