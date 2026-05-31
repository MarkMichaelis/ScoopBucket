function Get-Package {
    <#
    .SYNOPSIS
        List every package declared by every bundle in this bucket.

    .DESCRIPTION
        Walks `bucket/*.ps1` in a fresh child runspace and captures the
        `[Package[]]` collection each migrated bundle assigns to
        `$Packages` before its `Invoke-PackageInstall` call. Returns the
        flattened list with the originating bundle's name attached so
        cross-bundle tooling (Test-Installs.ps1 verification,
        CLI-availability discovery) can collapse onto a single source
        of truth.

        Filters:
          -Name <wildcards…>      Match Package.Name (case-insensitive).
          -Installer <enum…>      Filter by engine: winget/scoop/choco/
                                  npmGlobal/dotnetTool/custom.
          -Bundle <names…>        Restrict to specific bundles.

        Note: this Get-Package shadows
        `PackageManagement\Get-Package` for the current session. The
        OneGet cmdlet remains reachable via its full module-qualified
        name.

    .PARAMETER Name
        One or more wildcard patterns matched against Package.Name.

    .PARAMETER Installer
        Filter by engine type.

    .PARAMETER Bundle
        Restrict to one or more bundle names (file stem without .ps1).

    .PARAMETER BucketPath
        Override the auto-detected bucket directory.

    .OUTPUTS
        PSCustomObject[] with Bundle, Name, Installer, Id, Source, Scope,
        CliCommands, Completion, DependsOn, Companions, CISkip, Notes, WingetExtraArgs.

    .EXAMPLE
        Get-Package -Installer scoop
        # List every scoop-installed package across all bundles.

    .EXAMPLE
        Get-Package -Name 'rip*','Bit*'
        # Wildcard match across all bundles.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [string[]]$Name,
        [ValidateSet('winget','scoop','choco','npmGlobal','dotnetTool','custom')]
        [string[]]$Installer,
        [string[]]$Bundle,
        [string]$BucketPath
    )

    $bundleArgs = @{}
    if ($BucketPath) { $bundleArgs['BucketPath'] = $BucketPath }
    $bundles = Get-BundlePackages @bundleArgs

    $flat = New-Object System.Collections.Generic.List[object]
    foreach ($b in $bundles) {
        if ($Bundle -and ($b.Bundle -notin $Bundle)) { continue }
        foreach ($p in $b.Packages) {
            # Get-BundlePackages round-trips through JSON, so hashtables
            # arrive as PSCustomObjects. Restore them to real Hashtables
            # here so callers (tests, sweep loops) can use .ContainsKey()
            # and indexer syntax uniformly.
            $expected = @{}
            if ($p.ExpectedCompletions) {
                if ($p.ExpectedCompletions -is [hashtable]) {
                    $expected = $p.ExpectedCompletions
                } else {
                    foreach ($prop in $p.ExpectedCompletions.PSObject.Properties) {
                        $expected[$prop.Name] = @($prop.Value)
                    }
                }
            }
            $nativeOutputs = @{}
            if ($p.PSObject.Properties.Name -contains 'NativeCommandOutputs' -and $p.NativeCommandOutputs) {
                if ($p.NativeCommandOutputs -is [hashtable]) {
                    $nativeOutputs = $p.NativeCommandOutputs
                } else {
                    foreach ($prop in $p.NativeCommandOutputs.PSObject.Properties) {
                        $nativeOutputs[$prop.Name] = [string]$prop.Value
                    }
                }
            }
            $obj = [pscustomobject]@{
                Bundle      = $b.Bundle
                Name        = $p.Name
                Installer   = $p.Installer
                Id          = $p.Id
                Source      = $p.Source
                Scope       = $p.Scope
                CliCommands = @($p.CliCommands)
                Completion  = $p.Completion
                ExpectedCompletions = $expected
                NativeCommandOutputs = $nativeOutputs
                DependsOn   = @($p.DependsOn)
                Companions  = @($p.Companions)
                CISkip      = $p.CISkip
                Notes       = $p.Notes
                WingetExtraArgs = @($p.WingetExtraArgs)
                UpdateTimeoutMinutes = [int]$p.UpdateTimeoutMinutes
                HasPostInstallScript   = [bool]$p.HasPostInstallScript
                HasPostUpdateScript    = [bool]$p.HasPostUpdateScript
                HasCustomInstallScript = [bool]$p.HasCustomInstallScript
                HasVerifyScript        = [bool]$p.HasVerifyScript
                HasNativeCommandScript = [bool]$p.HasNativeCommandScript
            }
            $flat.Add($obj)
        }
    }

    $results = $flat.ToArray()

    if ($Name) {
        $results = $results | Where-Object {
            $candidate = $_
            foreach ($pattern in $Name) {
                if ($candidate.Name -like $pattern) { return $true }
            }
            $false
        }
    }
    if ($Installer) {
        $results = $results | Where-Object { $_.Installer -in $Installer }
    }

    # Return the flat list. Callers should still wrap in @() if they
    # need a strict array (e.g. for .Count when 0/1 results are possible);
    # we deliberately do NOT pre-wrap with `,$results` because that would
    # add an extra outer array layer once the caller's own @() applies.
    return $results
}
