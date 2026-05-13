function Get-Package {
    <#
    .SYNOPSIS
        List packages defined across all bundles in this ScoopBucket.

    .DESCRIPTION
        Cross-bundle aggregator. Scans every bucket/*.ps1 for Package
        entries and returns a flat list with Name / Bundle / Installer /
        CliCommands / Installed columns. Supports wildcard search by Name
        and an -Installed filter that uses each engine's list query.

        Deliberately shadows the built-in PackageManagement\Get-Package
        cmdlet.

        NOTE: this is a stub. The full implementation lands in the
        install-package-helper phase.

    .PARAMETER Name
        Name or wildcard pattern to filter by.

    .PARAMETER Installed
        Return only packages whose engine reports them as installed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string] $Name = '*',
        [switch] $Installed
    )

    throw "Get-Package: not yet implemented (install-package-helper phase). Requested pattern: '$Name'"
}
