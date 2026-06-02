function Update-PackageConfig {
    <#
    .SYNOPSIS
        Re-apply the declarative ConfigScript for packages in this bucket
        without reinstalling or updating them.

    .DESCRIPTION
        Configuration declared on a Package via its ConfigScript is
        idempotent machine configuration (for example the MCP-server wiring
        in the AIAgents bundle). The install / update drivers already run it
        automatically on every install and every update, but there are times
        you want to re-apply it on demand -- after restoring a dev machine,
        after editing a config bundle, or simply to "refresh the MCP servers"
        without touching the installed apps.

        Update-PackageConfig walks every declarative bundle via
        Get-BundlePackages, reconstructs the real [Package] objects
        (ConfigScript scriptblocks intact) for each matching bundle through
        Get-BundlePackageObjects, and invokes each package's ConfigScript.
        Packages with no ConfigScript are ignored.

        This is the on-demand counterpart to Update-PackageCompletion: where
        that command refreshes tab-completion blocks, this one refreshes
        package configuration.

    .PARAMETER Name
        One or more package OR bundle names to refresh (matched
        case-insensitively against Package.Name and the bundle name). Omit
        the parameter (or pass '*') to refresh every package that declares a
        ConfigScript across the whole bucket.

    .PARAMETER BucketPath
        Override the auto-detected bucket directory (forwarded to
        Get-BundlePackages / Get-BundlePackageObjects).

    .OUTPUTS
        PSCustomObject[] -- one row per package that declares a ConfigScript,
        with Package, Bundle, Action (Applied | WhatIf | Failed) and Reason.

    .EXAMPLE
        Update-PackageConfig AIAgents

        Re-apply the AIAgents configuration (re-wires the MCP servers).

    .EXAMPLE
        Update-PackageConfig

        Re-apply every package's ConfigScript across the bucket.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Position = 0)][string[]]$Name,
        [string]$BucketPath
    )

    $bundleArgs = @{}
    if ($BucketPath) { $bundleArgs['BucketPath'] = $BucketPath }
    $bundles = Get-BundlePackages @bundleArgs

    # A null / empty / '*' filter means "every package in every bundle".
    $matchAll = (-not $Name) -or ($Name -contains '*')

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($b in $bundles) {
        if (-not $b.Packages -or $b.Packages.Count -eq 0) { continue }

        # Does this bundle have anything in scope? When a filter is supplied,
        # the bundle is in scope if its name matches OR any of its package
        # names match -- so a bundle-name request harvests the whole bundle
        # and a package-name request harvests just the named package(s).
        $bundleNameMatches = $false
        if (-not $matchAll) {
            foreach ($n in $Name) {
                if ($b.Bundle -ieq $n) { $bundleNameMatches = $true; break }
            }
        }

        $wantNames = $null
        if (-not $matchAll -and -not $bundleNameMatches) {
            $wantNames = @($b.Packages | Where-Object { $Name -contains $_.Name } | ForEach-Object Name)
            if (-not $wantNames -or $wantNames.Count -eq 0) { continue }
        }

        # Reconstruct the real [Package] objects (scriptblocks intact). Only
        # this harvest path preserves ConfigScript; the metadata-only
        # Get-BundlePackages round-trip strips scriptblocks.
        $pkgObjects = @(Get-BundlePackageObjects -BundlePath $b.BundlePath)

        foreach ($p in $pkgObjects) {
            if (-not $p.ConfigScript) { continue }
            if ($wantNames -and ($wantNames -notcontains $p.Name)) { continue }

            if ($WhatIfPreference) {
                $results.Add([pscustomobject]@{
                    Package = $p.Name; Bundle = $b.Bundle
                    Action  = 'WhatIf'; Reason = ''
                })
                continue
            }

            if (-not $PSCmdlet.ShouldProcess("$($b.Bundle)/$($p.Name)", 'Re-apply ConfigScript')) {
                $results.Add([pscustomobject]@{
                    Package = $p.Name; Bundle = $b.Bundle
                    Action  = 'Skipped'; Reason = 'Declined at the confirmation prompt.'
                })
                continue
            }

            try {
                [void](& $p.ConfigScript $p 2>$null)
                $results.Add([pscustomobject]@{
                    Package = $p.Name; Bundle = $b.Bundle
                    Action  = 'Applied'; Reason = ''
                })
            } catch {
                $results.Add([pscustomobject]@{
                    Package = $p.Name; Bundle = $b.Bundle
                    Action  = 'Failed'; Reason = "ConfigScript threw: $($_.Exception.Message)"
                })
                Write-Error "Update-PackageConfig: $($b.Bundle)/$($p.Name) ConfigScript threw: $($_.Exception.Message)"
            }
        }
    }

    $arr = $results.ToArray()
    $byAction = $arr | Group-Object Action | ForEach-Object { "$($_.Name)=$($_.Count)" }
    if ($byAction) {
        Write-Verbose "Update-PackageConfig: $($byAction -join ', ')"
    } else {
        Write-Verbose 'Update-PackageConfig: no packages declare a ConfigScript.'
    }

    return , $arr
}
