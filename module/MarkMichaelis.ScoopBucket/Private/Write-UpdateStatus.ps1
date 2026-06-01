# Transient "live logging" for the update path (#276).
#
# The update flow (Update-Package -> Invoke-PackageUpdate -> Update-*Package,
# plus the machine-wide Invoke-AllEnginesUpdate) used to print every step via
# Write-Host: section headers, per-package "[update] ..." lines, the engine
# command echo, and the raw installer output. All of that landed in the
# scrollback and was captured whenever the caller redirected output.
#
# The only artifact the user wants to persist is the final summary table.
# Everything else is routed here so it is:
#   * Transient   -- Write-Progress draws to the host's progress region and
#                    auto-clears when the run completes.
#   * Never redirected -- the progress stream is the only output that is not
#                    one of the six redirectable streams (1/2/3/4/5/6), so
#                    `Update-Package * *> log` / `| ...` capture only the table
#                    (and the [Package] pipeline objects), never this chatter.
#   * Recoverable -- the same text is mirrored to Write-Verbose, so `-Verbose`
#                    reveals the full log persistently and `4>&1` captures it.
#
# Callers that need the raw installer output for failure diagnosis should keep
# it in the engine's @{ State; Reason } record (surfaced in the summary row);
# this helper is purely for the transient/verbose live view.

function Write-UpdateStatus {
    [CmdletBinding()]
    param(
        # The status text (e.g. "Updating Warp (winget)..."). Mandatory unless
        # -Completed is used to tear the progress line down.
        [Parameter(Position = 0)][string]$Status,
        [string]$Activity = 'Update-Package',
        [int]$Id = 1,
        [int]$ParentId = -1,
        # 0-100; omit (or -1) when no meaningful percentage exists.
        [int]$PercentComplete = -1,
        # Clear the progress line (call once before rendering the final table).
        [switch]$Completed
    )

    if ($Completed) {
        Write-Progress -Activity $Activity -Id $Id -Completed
        return
    }

    if (-not $Status) { return }

    # Persistent-on-demand copy: hidden unless the caller passed -Verbose, in
    # which case it shows inline and is captured by 4>. $VerbosePreference is
    # inherited from the calling cmdlet's scope, so engines invoked without an
    # explicit -Verbose still honour a -Verbose on Update-Package.
    Write-Verbose $Status

    # Transient live copy: never captured by redirection, auto-clears on
    # completion. Safe (no-op) on non-interactive hosts and honours a caller
    # who set $ProgressPreference = 'SilentlyContinue'.
    $progressArgs = @{ Activity = $Activity; Status = $Status; Id = $Id }
    if ($ParentId -ge 0)        { $progressArgs['ParentId']        = $ParentId }
    if ($PercentComplete -ge 0) { $progressArgs['PercentComplete'] = [Math]::Min(100, [Math]::Max(0, $PercentComplete)) }
    Write-Progress @progressArgs
}

function Get-CapturedOutputTail {
    # Build a short, single-line tail of captured installer output to fold into a
    # failed engine's Reason so the summary row stays debuggable without -Verbose
    # or a re-run. Returns '' for empty input (so it appends nothing).
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Output,
        [int]$Lines = 3
    )

    if ([string]::IsNullOrWhiteSpace($Output)) { return '' }

    $tail = ($Output -split "`r?`n" |
        Where-Object { $_.Trim() } |
        Select-Object -Last $Lines) -join ' | '

    if (-not $tail) { return '' }
    return " Last output: $tail"
}
