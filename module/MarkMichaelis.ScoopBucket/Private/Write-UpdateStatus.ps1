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

    # Forward to the host-adaptive pane (#354/#361). Write-LivePane owns the verbose
    # mirror and, per Resolve-LiveOutputMode, renders either the bottom-anchored sticky
    # status bar over a persistent scrolling log (capable interactive VT console) or the
    # original single-line Write-Progress region (CI / redirected / VS Code / no-VT /
    # too-short window) or verbose-only (progress silenced). In CI and under redirection
    # the mode is always Single, so the #276 behaviour -- transient Write-Progress plus a
    # -Verbose mirror -- is preserved exactly. Callers MUST invoke this with -Completed in
    # a finally so an aborted run resets the VT scroll region.
    $forward = @{ Activity = $Activity; Id = $Id; ParentId = $ParentId; PercentComplete = $PercentComplete }
    if ($Completed) {
        Write-LivePane @forward -Completed
        return
    }
    if ($Status) { $forward['Status'] = $Status }
    Write-LivePane @forward
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
