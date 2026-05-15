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

        Returns the array of summary records and stores it on
        `$global:LASTINSTALLREPORT` for cross-bundle inspection.

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

    .PARAMETER ForceCompletion
        Pass -Force through to Register-PackageCompletion so existing
        sentinel blocks are replaced rather than preserved.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][object[]]$Packages,
        [Parameter(Mandatory)][string]$Bundle,
        [string[]]$Name,
        [string[]]$Skip,
        [switch]$DryRun,
        [switch]$SkipCompletion,
        [switch]$ForceCompletion
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

    $summary = New-Object System.Collections.Generic.List[object]
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
        $record = [pscustomobject]@{
            Bundle      = $Bundle
            Name        = $pkg.Name
            Installer   = $pkg.Installer
            Id          = $pkg.Id
            Scope       = $pkg.Scope
            CliCommands = $pkg.CliCommands
            State       = 'Pending'
            Reason      = $null
            Verified    = $null
            Completion  = $null
        }

        if ($pkg.CISkip -and $isCi) {
            $record.State  = 'Skipped'
            $record.Reason = "CISkip: $($pkg.CISkip)"
            Write-Host "[skip] $($pkg.Name) -- $($record.Reason)"
            $summary.Add($record)
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
                    & $pkg.CustomInstallScript $pkg
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
            $record.State  = $result.State
            $record.Reason = $result.Reason
        } catch {
            $record.State  = 'Failed'
            $record.Reason = "Install threw: $($_.Exception.Message)"
            Write-Warning "  $($pkg.Name): $($record.Reason)"
            $summary.Add($record)
            continue
        }

        if (-not $DryRun) { Update-PathFromRegistry }

        if ($pkg.PostInstallScript -and $record.State -ne 'Failed') {
            if ($DryRun) {
                Write-Host "  [DryRun] PostInstallScript"
            } else {
                try {
                    & $pkg.PostInstallScript $pkg
                    Update-PathFromRegistry
                } catch {
                    $record.State  = 'Failed'
                    $record.Reason = "PostInstallScript threw: $($_.Exception.Message)"
                    Write-Warning "  $($pkg.Name): $($record.Reason)"
                    $summary.Add($record)
                    continue
                }
            }
        }

        if (-not $DryRun -and $record.State -ne 'Failed') {
            $record.Verified = Test-PackageInstalled -Package $pkg
            if (-not $record.Verified -and ($pkg.CliCommands.Count -gt 0 -or $pkg.VerifyScript)) {
                Write-Warning "  $($pkg.Name): verification failed (CliCommands not on PATH and/or VerifyScript=false)."
            }
        }

        if (-not $SkipCompletion -and -not $DryRun -and
            $pkg.Completion -ne 'none' -and $pkg.CliCommands.Count -gt 0) {
            $completionResults = New-Object System.Collections.Generic.List[object]
            foreach ($cli in $pkg.CliCommands) {
                $registerArgs = @{ Cli = $cli; Mode = $pkg.Completion; Force = $ForceCompletion }
                if ($pkg.NativeCommandScript) { $registerArgs['NativeCommand'] = $pkg.NativeCommandScript }
                try {
                    $r = Register-PackageCompletion @registerArgs
                    $completionResults.Add($r)
                } catch {
                    Write-Warning "  $($pkg.Name)/$cli completion registration failed: $($_.Exception.Message)"
                    $completionResults.Add([pscustomobject]@{
                        Cli = $cli; Source = 'Skipped'; Action = 'Skipped'
                        Reason = $_.Exception.Message
                    })
                }
            }
            $record.Completion = $completionResults.ToArray()
        }

        $summary.Add($record)
    }

    $arr = $summary.ToArray()
    $global:LASTINSTALLREPORT = $arr

    Write-Host ""
    Write-Host "=== $Bundle summary ==="
    $arr | ForEach-Object {
        $line = "  {0,-18} {1,-12} {2}" -f $_.State, $_.Installer, $_.Name
        if ($_.Reason) { $line += "  -- $($_.Reason)" }
        Write-Host $line
    }
    Write-Host ""

    return ,$arr
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
