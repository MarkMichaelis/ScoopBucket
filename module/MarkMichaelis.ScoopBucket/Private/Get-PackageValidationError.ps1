function Get-PackageValidationError {
    <#
    .SYNOPSIS
        Validate a single [Package] without throwing, returning the first
        cross-field invariant violation as a string (or $null when valid).

    .DESCRIPTION
        Wraps [Package].Validate() (plus null / wrong-type guards) so the
        batch drivers (Invoke-PackageInstall / Invoke-PackageUpdate) can
        treat a malformed declaration as a per-package Failed result and
        keep going, instead of letting one bad package abort the whole
        sweep with a terminating throw.

        Shared by both drivers so install and update enforce the same
        invariants and the same fail-one-continue-rest resilience. The
        only packages that should NOT continue past a failure are
        dependents of the failed package, which the callers handle via
        DependsOn ordering.

    .PARAMETER Package
        The object to validate. Accepts $null so callers can route a
        null/garbage array entry into the same Failed path.

    .OUTPUTS
        [string] error message when invalid; $null when valid.

    .NOTES
        Deliberately a SIMPLE function (no [CmdletBinding()] and no
        [Parameter()] attributes). An advanced function re-surfaces a
        terminating error caught from a PowerShell class method as a
        non-terminating ErrorRecord on the caller's error stream, so a
        single invalid package would leak a spurious raw-throw record IN
        ADDITION to the driver's structured PackageInstallFailed /
        PackageUpdateFailed error. Keeping this a simple function lets the
        try/catch fully absorb the Validate() throw.
    #>
    [OutputType([string])]
    param(
        $Package
    )

    if ($null -eq $Package) {
        return 'package entry is null.'
    }
    if ($Package.GetType().Name -ne 'Package') {
        return "expected a [Package]; got [$($Package.GetType().FullName)]."
    }

    # A PowerShell `class` is keyed by name within a session: once one module
    # version's [Package] is loaded, Import-Module -Force on a newer version
    # does NOT redefine the cached type, so an object may be a STALE [Package]
    # that pre-dates GetValidationError(). Its type name is still 'Package'
    # (so the guard above passes), but the method is absent. Probe for it and
    # skip the non-throwing pre-check rather than throwing an InvalidOperation:
    # the engine layer still surfaces any real per-package failure, and a fresh
    # session (or a merge that updates the installed module) restores full
    # validation. This keeps the sweep resilient under dev-time hot-reload and
    # cross-version module coexistence.
    if (-not $Package.PSObject.Methods['GetValidationError']) {
        return $null
    }

    # Use the NON-throwing core so probing an invalid package does not leak a
    # spurious raw-throw ErrorRecord onto the advanced-function driver's error
    # stream (see Package.GetValidationError() for the full rationale).
    return $Package.GetValidationError()
}
