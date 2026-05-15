function Update-PackageCompletion {
    <#
    .SYNOPSIS
        Repair / refresh tab-completion sentinel blocks for every
        Package in the bucket whose CliCommand is on PATH and whose
        Completion mode requests PSCompletions-backed completion.

    .DESCRIPTION
        Solves the "I installed Bitwarden CLI, then installed
        PSCompletions, but `bw <Tab>` still only completes files"
        scenario.

        The cause: when the CLI was originally installed, PSCompletions
        was missing, so Register-PackageCompletion fell through to its
        'Skipped' branch and never wrote a sentinel block. Installing
        PSCompletions afterwards doesn't retroactively re-register the
        already-installed CLIs.

        Update-PackageCompletion walks every declarative bundle via
        Get-BundlePackages, finds Packages whose Completion mode is
        'pscompletions' (or 'auto' without a NativeCommandScript) and
        whose CliCommands resolve via Get-Command, then calls
        Register-PackageCompletion for each. Existing sentinel blocks
        are preserved unless -Force is passed.

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

    foreach ($b in $bundles) {
        foreach ($p in $b.Packages) {
            if (-not $p.CliCommands -or $p.CliCommands.Count -eq 0) { continue }
            $mode = "$($p.Completion)"
            if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'auto' }
            if ($mode -notin @('pscompletions','auto')) { continue }

            # 'auto' with a native scriptblock is best-handled by the
            # original install path which has the actual native command.
            # We can only safely repair pscompletions-mode CLIs here.
            $effectiveMode = $mode
            if ($mode -eq 'auto') {
                if ($p.HasNativeCommandScript) {
                    foreach ($cli in $p.CliCommands) {
                        $results.Add([pscustomobject]@{
                            Cli = $cli; Package = $p.Name; Bundle = $b.Bundle
                            Mode = $mode; Action = 'Skipped'; Source = 'Skipped'
                            Reason = "Package declares Completion='auto' with a native scriptblock; re-run Install-Package -ForceCompletion to refresh native completion."
                        })
                    }
                    continue
                }
                $effectiveMode = 'pscompletions'
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

                $action = "Register PSCompletions block for '$cli'"
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
                    Force = $true   # Always overwrite during repair.
                }
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
