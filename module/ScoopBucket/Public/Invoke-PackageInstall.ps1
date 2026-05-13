function Invoke-PackageInstall {
    <#
    .SYNOPSIS
        Install a collection of Package descriptors.

    .DESCRIPTION
        Processes a [Package[]] collection: validates each entry, sorts by
        DependsOn, then runs the install pipeline (AlreadyInstalled probe,
        engine install or CustomInstallScript, PostInstallScript, CLI
        verification, completion registration, VerifyScript) for each
        package. Emits a structured summary report.

        NOTE: this is a stub. The full pipeline lands in the driver-core /
        driver-completion phases of the refactor; for now it only validates
        and topo-sorts.

    .PARAMETER Packages
        The Package[] collection from a bundle.

    .PARAMETER Bundle
        Bundle name for logs and reporting.

    .PARAMETER Name
        When set, filter to these package Names plus their transitive
        DependsOn closure.

    .PARAMETER Skip
        Package Names to exclude.

    .PARAMETER WhatIf
        Dry-run: validate, sort, and log but do not install.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][Package[]] $Packages,
        [Parameter(Mandatory)][string]    $Bundle,
        [string[]] $Name,
        [string[]] $Skip
    )

    foreach ($pkg in $Packages) { $pkg.Validate() }

    $sorted = Resolve-PackageOrder -Packages $Packages -Name $Name -Skip $Skip

    foreach ($pkg in $sorted) {
        if ($pkg.CISkip -and ($env:CI -or $env:GITHUB_ACTIONS -eq 'true')) {
            Write-Host "[$Bundle] Skipping $($pkg.Name) in CI: $($pkg.CISkip)"
            continue
        }

        if ($PSCmdlet.ShouldProcess($pkg.Name, "Install ($($pkg.Installer))")) {
            throw "Invoke-PackageInstall: install pipeline not yet implemented (driver-core phase). Bundle='$Bundle' Package='$($pkg.Name)'."
        }
    }
}
