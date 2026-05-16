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

        Returns one PSCustomObject per package with:
          Bundle, Name, Installer, Id, Scope, State, Reason
        where State ∈ Uninstalled | NotInstalled | Failed | Skipped.

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
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][object[]]$Packages,
        [Parameter(Mandatory)][string]$Bundle,
        [string[]]$Name,
        [switch]$DryRun,
        [switch]$KeepCompletion,
        [switch]$SkipCompletion,
        [string]$ProfilePath
    )

    foreach ($pkg in $Packages) {
        if ($null -eq $pkg) {
            throw "Invoke-PackageUninstall: Packages array contains a null entry."
        }
        if ($pkg.GetType().Name -ne 'Package') {
            throw "Invoke-PackageUninstall: every element must be a [Package]; got [$($pkg.GetType().FullName)]."
        }
        $pkg.Validate()
    }

    $filtered = if ($Name -and $Name.Count -gt 0) {
        $Packages | Where-Object { $Name -contains $_.Name }
    } else { $Packages }
    $filtered = @($filtered)

    Write-Host ""
    Write-Host "=== Invoke-PackageUninstall: $Bundle ($($filtered.Count) packages) ==="

    $summary = New-Object System.Collections.Generic.List[object]
    $isCi = [bool]$env:CI

    foreach ($pkg in $filtered) {
        $record = [pscustomobject]@{
            Bundle    = $Bundle
            Name      = $pkg.Name
            Installer = $pkg.Installer
            Id        = $pkg.Id
            Scope     = $pkg.Scope
            State     = 'Pending'
            Reason    = $null
        }

        if ($pkg.CISkip -and $isCi) {
            $record.State  = 'Skipped'
            $record.Reason = "CISkip: $($pkg.CISkip)"
            Write-Host "[skip] $($pkg.Name) -- $($record.Reason)"
            $summary.Add($record)
            continue
        }

        Write-Host ""
        Write-Host "[uninstall] $pkg"

        try {
            if ($pkg.Installer -eq 'custom') {
                if (-not $pkg.CustomUninstallScript) {
                    $record.State  = 'Skipped'
                    $record.Reason = "Installer='custom' but no CustomUninstallScript on Package."
                    Write-Host "  $($record.Reason)"
                    $summary.Add($record)
                    continue
                }
                if ($DryRun) {
                    Write-Host "  [DryRun] CustomUninstallScript"
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
            $record.State  = $result.State
            $record.Reason = $result.Reason
        } catch {
            $record.State  = 'Failed'
            $record.Reason = "Uninstall threw: $($_.Exception.Message)"
            Write-Warning "  $($pkg.Name): $($record.Reason)"
            $summary.Add($record)
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

        $summary.Add($record)
    }

    $arr = $summary.ToArray()
    $global:LASTUNINSTALLREPORT = $arr

    Write-Host ""
    Write-Host "=== $Bundle uninstall summary ==="
    $arr | ForEach-Object {
        $line = "  {0,-14} {1,-12} {2}" -f $_.State, $_.Installer, $_.Name
        if ($_.Reason) { $line += "  -- $($_.Reason)" }
        Write-Host $line
    }
    Write-Host ""

    return ,$arr
}
