function Install-Package {
    <#
    .SYNOPSIS
        Install one or more packages from any bundle in this ScoopBucket.

    .DESCRIPTION
        Cross-bundle entry point. Scans every bucket/*.ps1 for Package
        entries, locates the requested package by Name, then dispatches to
        the owning bundle via Invoke-PackageInstall -Name <name>. The
        underlying driver auto-installs the transitive DependsOn closure
        first, so `Install-Package BitwardenCli` installs Bitwarden before
        the CLI.

        Deliberately shadows the built-in PackageManagement\Install-Package
        cmdlet (which is rarely used in modern PowerShell). The OneGet
        cmdlet remains reachable as PackageManagement\Install-Package.

        NOTE: this is a stub. The full implementation lands in the
        install-package-helper phase.

    .PARAMETER Name
        Package Name (exact match) to install.

    .PARAMETER WhatIf
        Dry-run: locate, validate, and log but do not install.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string[]] $Name
    )

    throw "Install-Package: not yet implemented (install-package-helper phase). Requested: $($Name -join ', ')"
}
