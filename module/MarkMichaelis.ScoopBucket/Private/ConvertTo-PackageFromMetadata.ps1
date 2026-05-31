function ConvertTo-PackageFromMetadata {
    <#
    .SYNOPSIS
        Internal: rebuild a [Package] from the JSON-deserialized metadata
        Get-BundlePackages returns. Scriptblock-typed fields are lost
        (they round-tripped through ConvertTo-Json) — callers that need
        CustomUninstallScript / PostUpdateScript must instead source the
        bundle via Get-BundlePackageObjects.

        Shared by Uninstall-Package and Update-Package as the fallback
        path when in-process dot-sourcing of the bundle is unavailable.
        Lives in Private/ so neither cmdlet has a hidden cross-file
        dot-sourcing dependency on the other.
    #>
    param([Parameter(Mandatory)][object]$Metadata)

    $pkg = [Package]@{
        Name        = $Metadata.Name
        Installer   = $Metadata.Installer
        Id          = $Metadata.Id
        Source      = if ($Metadata.PSObject.Properties['Source']) { [string]$Metadata.Source } else { '' }
        Scope       = if ($Metadata.PSObject.Properties['Scope']) { [string]$Metadata.Scope } else { 'global' }
        CliCommands = @($Metadata.CliCommands)
        Completion  = if ($Metadata.PSObject.Properties['Completion']) { [string]$Metadata.Completion } else { 'none' }
        DependsOn   = @($Metadata.DependsOn)
        Companions  = if ($Metadata.PSObject.Properties['Companions']) { @($Metadata.Companions) } else { @() }
        CISkip      = if ($Metadata.PSObject.Properties['CISkip']) { [string]$Metadata.CISkip } else { '' }
        Notes       = if ($Metadata.PSObject.Properties['Notes']) { [string]$Metadata.Notes } else { '' }
        # WingetExtraArgs must round-trip through the metadata-only
        # fallback or winget upgrade/uninstall commands lose declared
        # extras like --skip-dependencies (the very reason a bundle
        # bothered to set the field). Get-BundlePackages emits this
        # field in the probe projection; copy it back here.
        WingetExtraArgs = if ($Metadata.PSObject.Properties['WingetExtraArgs']) { @($Metadata.WingetExtraArgs) } else { @() }
    }
    # Completion's ExpectedCompletions invariant only matters at install
    # time; reconstruct enough to satisfy Validate() for non-'none' modes.
    if ($pkg.Completion -ne 'none') {
        $ec = @{}
        foreach ($cli in $pkg.CliCommands) { $ec[$cli] = @('--help') }
        $pkg.ExpectedCompletions = $ec
        # Validate() requires a NativeCommandScript for native/auto. Since
        # this is the uninstall/update path we never run it; supply a sentinel.
        if ($pkg.Completion -in @('native','auto')) {
            $pkg.NativeCommandScript = { '' }
        }
    }
    return $pkg
}
