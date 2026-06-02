function Select-PackageResultSummary {
    <#
    .SYNOPSIS
        Apply the default "changed rows only" view to a collected set of
        PackageResults and print a one-line host summary of the rows that were
        suppressed (#283).

    .DESCRIPTION
        Update-Package / Install-Package collect every PackageResult their
        drivers emit (the full ledger) and pipe them through this helper before
        returning to the user. By default only rows that represent an actual
        change -- Updated / Installed / Uninstalled / Failed -- are emitted on
        the success stream, and a host-only line (Write-Host, never captured)
        reports the counts of the quiet rows, e.g.

            Hidden: 14 already latest, 2 self-managed, 1 not installed   (-IncludeUnchanged to show all)

        -IncludeUnchanged emits every row and omits the summary line. The line
        is host-only so piping / Export-Csv still sees a clean object stream,
        consistent with the #276 "only the table persists" design. PowerShell
        renders host writes before the auto-formatted object table, so the line
        appears just above the changed-only table.

    .PARAMETER Result
        The collected PackageResult objects (may be empty).

    .PARAMETER IncludeUnchanged
        Emit every row and skip the summary line.
    #>
    [OutputType([PackageResult])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Result,
        [switch]$IncludeUnchanged
    )

    # Rows that represent a real state change -- always shown.
    $changed = @('Updated', 'Installed', 'Uninstalled', 'Failed')

    if ($IncludeUnchanged) {
        foreach ($r in $Result) { $r }
        return
    }

    # Friendly label for each suppressed status, used to build the summary.
    $labels = @{
        AlreadyLatest       = 'already latest'
        AlreadyInstalled    = 'already installed'
        SelfManaged         = 'self-managed'
        NoAutoUpdateSupport = 'no auto-update'
        NotInstalled        = 'not installed'
        Skipped             = 'skipped'
    }

    $suppressed = @{}
    $shown = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Result) {
        if ($changed -contains $r.Status) {
            [void]$shown.Add($r)
            continue
        }
        $label = if ($labels.ContainsKey($r.Status)) { $labels[$r.Status] } else { $r.Status.ToLowerInvariant() }
        if ($suppressed.ContainsKey($label)) { $suppressed[$label]++ } else { $suppressed[$label] = 1 }
    }

    # Host-only summary of the suppressed rows. PowerShell renders host writes
    # before the auto-formatted object table, so this reads as a lead-in line
    # above the changed-only table (consistent with the dispatch messages the
    # drivers already emit). The object stream below stays clean for piping /
    # Export-Csv.
    if ($suppressed.Count -gt 0) {
        # Stable order: highest count first, then alphabetical, so the line
        # reads the same way run-to-run.
        $parts = $suppressed.GetEnumerator() |
            Sort-Object @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key'; Descending = $false } |
            ForEach-Object { "$($_.Value) $($_.Key)" }
        Write-Host ("Hidden: {0}   (-IncludeUnchanged to show all)" -f ($parts -join ', ')) -ForegroundColor DarkGray
        # Blank line so the host summary reads as a distinct lead-in above the
        # auto-formatted object table rather than colliding with its header.
        Write-Host ''
    }

    foreach ($r in $shown) { $r }
}
