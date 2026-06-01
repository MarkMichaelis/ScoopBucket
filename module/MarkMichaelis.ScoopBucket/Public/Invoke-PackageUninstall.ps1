function Invoke-PackageUninstall {
    <#
    .SYNOPSIS
        Bundle-driven uninstall pipeline. Mirrors Invoke-PackageInstall:
        validate every Package, walk the collection, dispatch to a
        per-installer uninstall, optionally strip the sentinel
        completion blocks the install wrote.

    .DESCRIPTION
        Called by Uninstall-Package after it resolves a user-requested
        Name (or bundle name) to a concrete [Package[]] collection.
        Honours -DryRun the same way Invoke-PackageInstall does (engines
        run with -WhatIf so no real CLI is invoked) and -KeepCompletion
        (preserve the profile sentinel block instead of removing it).

        Emits one [PackageResult] per package (Operation='Uninstall') on
        the success stream, rendered by the format.ps1xml view; Status ∈
        Uninstalled | NotInstalled | Failed | Skipped. Failed packages
        also emit a structured ErrorRecord on the error stream
        (FullyQualifiedErrorId = 'PackageUninstallFailed') and the sweep
        continues to the next package.

        CISkip honored same as install: if $env:CI is truthy and the
        package declared CISkip, the entry is skipped (State='Skipped').

        For Installer='custom', invokes Package.CustomUninstallScript when
        present; when absent, records State='Skipped' with a reason
        (installs may declare a CustomInstallScript that simply has no
        reversible counterpart).

    .PARAMETER Packages
        Declarative [Package[]] collection to uninstall (typically the
        Name-filtered subset Uninstall-Package resolved).

    .PARAMETER Bundle
        Originating bundle name — appears on each summary record.

    .PARAMETER Name
        Optional further filter. Only packages whose Name matches one of
        these entries are processed.

    .PARAMETER DryRun
        Plan only; engines receive -WhatIf and do not invoke the CLI.

    .PARAMETER KeepCompletion
        Preserve the sentinel completion block in
        $PROFILE.AllUsersAllHosts. Default removes it.

    .PARAMETER SkipCompletion
        Don't touch the profile at all (also skips removal). Useful when
        the profile isn't writable (e.g. unelevated CI).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([PackageResult])]
    param(
        [Parameter(Mandatory)][object[]]$Packages,
        [Parameter(Mandatory)][string]$Bundle,
        [string[]]$Name,
        [switch]$DryRun,
        [switch]$KeepCompletion,
        [switch]$SkipCompletion,
        [string]$ProfilePath
    )

    $filtered = if ($Name -and $Name.Count -gt 0) {
        $Packages | Where-Object { $Name -contains $_.Name }
    } else { $Packages }
    $filtered = @($filtered)

    # Order matters: companions and DependsOn-dependents must be
    # uninstalled BEFORE their owners/prerequisites so DependsOn
    # invariants are respected during teardown. Compute the install
    # order over the full bundle (so cross-cutting Companions / DependsOn
    # ordering edges are respected) and reverse the subset we're
    # actually going to uninstall.
    try {
        $installOrder = Resolve-PackageOrder -Packages $Packages
        $filteredSet  = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@($filtered | ForEach-Object { $_.Name }),
            [System.StringComparer]::OrdinalIgnoreCase
        )
        $orderedSubset = @($installOrder | Where-Object { $filteredSet.Contains($_.Name) })
        [array]::Reverse($orderedSubset)
        $filtered = $orderedSubset
    } catch {
        # Cycle or unresolved reference -- fall back to declaration
        # order; Resolve-PackageOrder's full-collection sort is best-
        # effort here. The driver-level Validate() above will have
        # rejected truly broken inputs.
        Write-Verbose "Invoke-PackageUninstall: Resolve-PackageOrder failed ($($_.Exception.Message)); falling back to declaration order."
    }

    Write-UpdateStatus -Activity 'Uninstall-Package' "Invoke-PackageUninstall: $Bundle ($($filtered.Count) packages)..."

    # Per-package outcome records; PackageResult emission is deferred until
    # after the loop so an interactive run renders a single table. A failed
    # package becomes a Failed row plus an ErrorRecord on the error stream
    # and the sweep continues (parity with install/update).
    $states = New-Object System.Collections.Generic.List[object]
    $isCi = [bool]$env:CI

    $addState = {
        param($p, $st, $rs, $err)
        $states.Add([pscustomobject]@{ Pkg = $p; State = $st; Reason = $rs; Err = $err })
    }

    $failPackage = {
        param($p, $rs, $name)
        $pkgName = if ($name) { $name } else { $p.Name }
        $errRec = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("${pkgName}: $rs"),
            'PackageUninstallFailed',
            [System.Management.Automation.ErrorCategory]::NotSpecified,
            $p)
        & $addState $p 'Failed' $rs $errRec
        $PSCmdlet.WriteError($errRec)
    }

    foreach ($pkg in $filtered) {
        # Validate per package (non-throwing) so a malformed declaration
        # fails just this one teardown and the batch continues — same
        # resilient sweep the install/update paths use.
        $declErr = Get-PackageValidationError $pkg
        if ($declErr) {
            $pkgName = if ($null -ne $pkg -and $pkg.PSObject.Properties.Name -contains 'Name') { $pkg.Name } else { '<unknown>' }
            & $failPackage $pkg "Invalid package declaration: $declErr" $pkgName
            continue
        }

        if ($pkg.CISkip -and $isCi) {
            $reason = "CISkip: $($pkg.CISkip)"
            Write-UpdateStatus -Activity 'Uninstall-Package' "[skip] $($pkg.Name) -- $reason"
            & $addState $pkg 'Skipped' $reason $null
            continue
        }

        Write-UpdateStatus -Activity 'Uninstall-Package' "[uninstall] $pkg"

        try {
            if ($pkg.Installer -eq 'custom') {
                if (-not $pkg.CustomUninstallScript) {
                    $reason = "Installer='custom' but no CustomUninstallScript on Package."
                    Write-UpdateStatus -Activity 'Uninstall-Package' "  $reason"
                    & $addState $pkg 'Skipped' $reason $null
                    continue
                }
                if ($DryRun) {
                    Write-UpdateStatus -Activity 'Uninstall-Package' "  [DryRun] CustomUninstallScript"
                    $result = @{ State = 'Uninstalled'; Reason = '(DryRun)' }
                } else {
                    & $pkg.CustomUninstallScript $pkg
                    $result = @{ State = 'Uninstalled'; Reason = $null }
                }
            } else {
                $result = switch ($pkg.Installer) {
                    'winget'      { Uninstall-WingetPackage     -Package $pkg -WhatIf:$DryRun }
                    'scoop'       { Uninstall-ScoopPackage      -Package $pkg -WhatIf:$DryRun }
                    'choco'       { Uninstall-ChocoPackage      -Package $pkg -WhatIf:$DryRun }
                    'npmGlobal'   { Uninstall-NpmGlobalPackage  -Package $pkg -WhatIf:$DryRun }
                    'dotnetTool'  { Uninstall-DotnetToolPackage -Package $pkg -WhatIf:$DryRun }
                    default       { throw "Invoke-PackageUninstall: unknown Installer '$($pkg.Installer)' for '$($pkg.Name)'." }
                }
            }
            $state  = $result.State
            $reason = $result.Reason
        } catch {
            & $failPackage $pkg "Uninstall threw: $($_.Exception.Message)"
            continue
        }

        if ($state -eq 'Failed') {
            & $failPackage $pkg $reason
            continue
        }

        # Strip sentinel completion blocks for each CliCommand unless
        # the caller asked us to keep them. NotInstalled / Failed don't
        # block removal: the block is just text in the profile and
        # there's no reason to keep an orphaned completer registered.
        if (-not $SkipCompletion -and -not $KeepCompletion -and -not $DryRun -and
            $pkg.CliCommands.Count -gt 0) {
            foreach ($cli in $pkg.CliCommands) {
                try {
                    $removeArgs = @{ Cli = $cli; Confirm = $false }
                    if ($ProfilePath) { $removeArgs['ProfilePath'] = $ProfilePath }
                    $null = Remove-PackageCompletionBlock @removeArgs
                } catch {
                    Write-Warning "  $($pkg.Name)/$cli completion block removal failed: $($_.Exception.Message)"
                }
            }
        }

        & $addState $pkg $state $reason $null
    }

    Write-UpdateStatus -Activity 'Uninstall-Package' -Completed

    # Emit one PackageResult per package on the success stream; the
    # format.ps1xml view renders Status as a colored glyph for interactive
    # display, while piped/exported consumers see the plain Status string.
    foreach ($s in $states) {
        [PackageResult]@{
            Operation = 'Uninstall'
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
