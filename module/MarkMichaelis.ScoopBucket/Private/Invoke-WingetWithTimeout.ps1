# Per-call winget wrapper with a hard timeout (#269).
#
# Why this exists:
#   `winget upgrade --silent --disable-interactivity` can still wedge on
#   installers that wait for the running app to exit (Squirrel-based apps
#   such as Warp.Warp). Without a hard timeout, a single hung package
#   stalls an entire bucket-scoped Update-Package sweep indefinitely (the
#   user has to Ctrl+C and lose progress on the rest of the bundle).
#
# Behavior:
#   * Launches winget via Start-Process -NoNewWindow -PassThru so its
#     stdout/stderr inherit the parent console (preserves the progress
#     spinner and user-visible output -- we don't want to swallow it the
#     way the install-time helper in .github/scripts does, because this
#     runs interactively).
#   * Waits up to $TimeoutSeconds for the process to exit. On timeout,
#     kills the process tree and returns @{ ExitCode = -1; TimedOut = $true }.
#   * On normal exit, returns @{ ExitCode = $proc.ExitCode; TimedOut = $false }.
#
# Callers should pass $TimeoutMinutes * 60 (Update-WingetPackage gates
# the call entirely when its -TimeoutMinutes is 0, so this helper is
# never invoked with TimeoutSeconds <= 0 in practice; the guard below
# is purely defensive).

function Invoke-WingetWithTimeout {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    if ($TimeoutSeconds -le 0) {
        # Defensive: a caller passed a non-positive timeout. Run with no
        # cap and report the real exit code; do not advertise TimedOut.
        & winget @Arguments
        return @{ ExitCode = $LASTEXITCODE; TimedOut = $false }
    }

    $proc = Start-Process -FilePath 'winget' -ArgumentList $Arguments `
        -NoNewWindow -PassThru
    $finished = $proc.WaitForExit([int]([math]::Min(2147483647L, [long]$TimeoutSeconds * 1000L)))

    if (-not $finished) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        return @{ ExitCode = -1; TimedOut = $true; DurationSeconds = $TimeoutSeconds }
    }

    return @{ ExitCode = $proc.ExitCode; TimedOut = $false }
}
