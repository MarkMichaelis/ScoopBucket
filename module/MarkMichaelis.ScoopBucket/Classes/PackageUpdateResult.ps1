# Result descriptor emitted by Update-Package / Invoke-PackageUpdate.
#
# Update-Package emits one PackageUpdateResult per package on the success
# stream. A custom format.ps1xml view (selected by this type name) renders
# the Status as a colorblind-safe glyph + color FOR DISPLAY ONLY -- the
# underlying Status stays a plain string so consumers can filter / export:
#
#   Update-Package '*' | Where-Object Status -eq 'Failed'
#   Update-Package '*' | Export-Csv results.csv
#
# Failures are first-class data here (Status='Failed', Reason=<message>,
# Error=<ErrorRecord>) AND are still written to the error stream by the
# emitter, so -ErrorVariable / $? / -ErrorAction Stop keep working.

class PackageUpdateResult {
    # Outcome of the update attempt. One of:
    #   Updated, AlreadyLatest, Skipped, Failed, NotInstalled,
    #   SelfManaged, NoAutoUpdateSupport.
    [string] $Status

    [string] $Name
    [string] $Installer
    [string] $Scope
    [string] $Id

    # The bundle this package was dispatched from.
    [string] $Bundle

    # Short human-readable detail for any status (e.g. '(WhatIf)',
    # 'CISkip: ...', or a failure's exception message). Surfaced inline by
    # the format view.
    [string] $Reason

    # Full structured error for Failed results ($null otherwise). Kept out
    # of the default table view but available on the object and via
    # Format-List, so failures stay programmatically inspectable:
    #   $r | Where-Object Status -eq 'Failed' | ForEach-Object { $_.Error.Exception }
    [System.Management.Automation.ErrorRecord] $Error

    [string] ToString() {
        return "[$($this.Status)] $($this.Name)$(if ($this.Id) { " ($($this.Id))" })"
    }
}
