# Result descriptor emitted by Install-Package / Update-Package /
# Uninstall-Package (and their Invoke-Package* drivers).
#
# Each driver emits one PackageResult per package on the success stream. A
# custom format.ps1xml view (selected by this type name) renders the Status as
# a colorblind-safe glyph + color FOR DISPLAY ONLY -- the underlying Status
# stays a plain string so consumers can filter / export:
#
#   Update-Package '*'  | Where-Object Status -eq 'Failed'
#   Install-Package Foo | Export-Csv results.csv
#
# Failures are first-class data here (Status='Failed', Reason=<message>,
# Error=<ErrorRecord>) AND are still written to the error stream by the
# emitter, so -ErrorVariable / $? / -ErrorAction Stop keep working.

class PackageResult {
    # Which verb produced this result: Install, Update, or Uninstall.
    [string] $Operation

    # Outcome of the attempt. The vocabulary is a superset across verbs:
    #   Update:    Updated, AlreadyLatest, Skipped, Failed, NotInstalled,
    #              SelfManaged, NoAutoUpdateSupport
    #   Install:   Installed, AlreadyInstalled, Skipped, Failed
    #   Uninstall: Uninstalled, NotInstalled, Skipped, Failed
    [string] $Status

    [string] $Name
    [string] $Installer
    [string] $Scope
    [string] $Id

    # The bundle this package was dispatched from.
    [string] $Bundle

    # Version transition for a real (or planned) upgrade/install. VersionFrom
    # is the version that was installed before the operation (empty for a
    # fresh install or when the engine couldn't be probed); VersionTo is the
    # version after (or the target under -WhatIf). Both feed the Details
    # column's `from -> to` rendering and stay on the object for export. See #283.
    [string] $VersionFrom
    [string] $VersionTo

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

    # Single human-readable cell merging the version transition and the
    # reason for the summary table's `Details` column (#283). Rules:
    #   Updated/Installed : 'Reinstalled', or 'from -> to', or '-> to' (fresh
    #                       install), suffixed ' (WhatIf)' on a dry run. A fresh
    #                       install with no known version and no other note
    #                       renders 'new install' rather than a blank cell.
    #   AlreadyLatest     : '<version> (latest)'.
    #   NotInstalled      : 'not installed'.
    #   SelfManaged       : 'self-managed'.
    #   NoAutoUpdate      : 'no auto-update'.
    #   Skipped/Failed/*  : the Reason verbatim (failure tail / skip cause).
    # The underlying VersionFrom/VersionTo/Reason properties stay intact for
    # export; this is presentation only.
    [string] Details() {
        $from = $this.VersionFrom
        $to   = $this.VersionTo
        $whatIf = ($this.Reason -match 'WhatIf')

        switch -Regex ($this.Status) {
            '^(Updated|Installed)$' {
                if ($this.Reason -match 'Reinstall') { $d = 'Reinstalled' }
                elseif ($from -and $to)              { $d = "$from -> $to" }
                elseif ($to)                         { $d = "-> $to" }
                elseif ($from)                       { $d = $from }
                else                                 { $d = '' }
                if ($whatIf) {
                    if ($d) { return "$d (WhatIf)" }
                    return [string]$this.Reason
                }
                if (-not $d) {
                    # A fresh install with no version transition and no other
                    # note would otherwise leave the Details cell blank; label
                    # it explicitly so a new install reads as such (#283).
                    if ($this.Status -eq 'Installed' -and -not $this.Reason) { return 'new install' }
                    return [string]$this.Reason
                }
                return $d
            }
            '^(AlreadyLatest|AlreadyInstalled)$' {
                if ($from) { return "$from (latest)" }
                return 'latest'
            }
            '^NotInstalled$'        { return 'not installed' }
            '^SelfManaged$'         { return 'self-managed' }
            '^NoAutoUpdateSupport$' { return 'no auto-update' }
            default                 { return [string]$this.Reason }
        }
        return [string]$this.Reason
    }
}
