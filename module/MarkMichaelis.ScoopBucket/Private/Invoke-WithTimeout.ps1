# Run an external command with a hard wall-clock timeout (#269, #271).
#
# Generalised from the helper that lived in
# .github/scripts/Test-Installs.ps1 so the module's update/install paths
# and the CI test harness can share one implementation.
#
# Behaviour:
#   * Launches `$FilePath` with `$Arguments` via Start-Process.
#   * `-CaptureOutput` redirects stdout/stderr to temp files and returns
#     the combined text in the `Output` field (the historical
#     Test-Installs.ps1 contract -- needed when you want to scrape the
#     output to classify failures).
#   * Without `-CaptureOutput` the child process inherits the parent
#     console, so the user sees live progress (needed by
#     Update-WingetPackage so the operator can watch winget's spinner).
#   * Waits up to `$TimeoutSeconds`. On expiry: kills the process tree
#     and returns @{ExitCode=-1; TimedOut=$true; DurationSeconds=...}.
#   * On normal exit: @{ExitCode=$proc.ExitCode; TimedOut=$false}.
#   * A non-positive `$TimeoutSeconds` disables the cap and invokes
#     the command directly so PowerShell function/alias mocks
#     (e.g. Pester `Mock winget`) still intercept it.

function Invoke-WithTimeout {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [switch]$CaptureOutput
    )

    if ($TimeoutSeconds -le 0) {
        # Defensive direct path: also preserves Pester's ability to mock
        # `winget`, `choco`, etc. as PowerShell functions in tests that
        # opt out of the timeout.
        if ($Arguments.Count -gt 0) { & $FilePath @Arguments } else { & $FilePath }
        return @{ ExitCode = $LASTEXITCODE; TimedOut = $false; Output = '' }
    }

    $spArgs = @{
        FilePath     = $FilePath
        NoNewWindow  = $true
        PassThru     = $true
    }
    if ($Arguments.Count -gt 0) { $spArgs['ArgumentList'] = $Arguments }

    $stdOut = $null
    $stdErr = $null
    if ($CaptureOutput) {
        $stdOut = [System.IO.Path]::GetTempFileName()
        $stdErr = [System.IO.Path]::GetTempFileName()
        $spArgs['RedirectStandardOutput'] = $stdOut
        $spArgs['RedirectStandardError']  = $stdErr
    }

    try {
        $proc = Start-Process @spArgs
        $finished = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $finished) {
            # Kill the whole child tree (Process.Kill($true)) so a hung wrapper
            # such as `cmd /c <cli>` cannot orphan a blocking child (e.g. a wsl
            # that waits on a distro). Fall back to Stop-Process if unavailable.
            try { $proc.Kill($true) }
            catch { try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { } }
            $partial = if ($CaptureOutput -and (Test-Path $stdOut)) { Get-Content $stdOut -Raw } else { '' }
            return @{
                ExitCode        = -1
                Output          = if ($CaptureOutput) { "$partial`n[TIMEOUT after ${TimeoutSeconds}s]" } else { '' }
                TimedOut        = $true
                DurationSeconds = $TimeoutSeconds
            }
        }
        $out = if ($CaptureOutput -and (Test-Path $stdOut)) { Get-Content $stdOut -Raw } else { '' }
        $err = if ($CaptureOutput -and (Test-Path $stdErr)) { Get-Content $stdErr -Raw } else { '' }
        return @{
            ExitCode = $proc.ExitCode
            Output   = if ($CaptureOutput) { "$out`n$err".Trim() } else { '' }
            TimedOut = $false
        }
    } finally {
        if ($CaptureOutput) {
            Remove-Item $stdOut, $stdErr -ErrorAction SilentlyContinue
        }
    }
}
