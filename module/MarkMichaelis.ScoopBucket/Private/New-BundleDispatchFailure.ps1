# Failed [PackageResult] for a dispatch that died before the driver could
# report per-package outcomes (#451).
#
# Install-Package / Update-Package drive each bundle through
# Invoke-PackageInstall / Invoke-PackageUpdate with
# `-ErrorAction Continue -ErrorVariable +pkgErrors`, which keeps the sweep
# alive across the driver's NON-terminating PackageInstallFailed records. It
# does nothing for a *terminating* error raised inside the driver: that
# propagates out of the call, skips the driver's result emission entirely, and
# used to abort the remainder of the sweep -- a machine converged only partway
# with no row explaining why (#451; the same resilience contract as #272).
#
# Callers catch such a failure and record it with this helper so the bundle
# still produces a Failed row, a structured ErrorRecord, and a non-zero
# `$?`, while the next bundle still gets its turn.

function New-BundleDispatchFailure {
    [OutputType([PackageResult])]
    [CmdletBinding()]
    param(
        # The bundle whose dispatch failed. Used as the result's Bundle and, in
        # the absence of -Name, as the row's Name.
        [Parameter(Mandatory)][string]$Bundle,
        [Parameter(Mandatory)][string]$Message,
        [string]$Name,
        [string]$Installer,
        [string]$Id,
        [ValidateSet('Install', 'Update', 'Uninstall')][string]$Operation = 'Install'
    )

    $label = if ($Name) { $Name } else { $Bundle }
    $errRec = [System.Management.Automation.ErrorRecord]::new(
        [System.Exception]::new("${label}: $Message"),
        "Package${Operation}Failed",
        [System.Management.Automation.ErrorCategory]::NotInstalled,
        $label)

    return [PackageResult]@{
        Operation = $Operation
        Status    = 'Failed'
        Name      = $label
        Installer = $Installer
        Id        = $Id
        Bundle    = $Bundle
        Reason    = $Message
        Error     = $errRec
    }
}
