<#
.SYNOPSIS
    Probe a binary with common help flags to confirm it runs.

.DESCRIPTION
    Phase 1.5 helper for issue #47. Given a binary path, attempts each
    of `/?`, `-?`, `--help`, `-h`, `/help` in order with a hard 5-second
    timeout per attempt (Start-Process + WaitForExit; killed on timeout).
    Returns the first flag that produces *any* stdout/stderr output and
    exits without being killed for timeout. If none succeed, returns a
    record with Success=$false.

    Output is captured to temp files in the current working directory's
    repo-local scratch (NOT /tmp) and removed after each probe.

.PARAMETER Path
    Full path to the executable to probe.

.PARAMETER TimeoutSeconds
    Per-flag timeout. Defaults to 5 seconds.

.OUTPUTS
    [pscustomobject] @{
        Path           = <input path>
        Flag           = <flag that worked, or $null>
        ExitCode       = <int, or $null on timeout>
        OutputSnippet  = <first 200 chars of combined stdout/stderr>
        Success        = <bool>
        TriedFlags     = <string[] of all flags attempted>
    }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Path,
    [int] $TimeoutSeconds = 5
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) {
    return [pscustomobject]@{
        Path = $Path; Flag = $null; ExitCode = $null
        OutputSnippet = '(file not found)'; Success = $false
        TriedFlags = @()
    }
}

$flags = @('/?','-?','--help','-h','/help')
$tried = [System.Collections.Generic.List[string]]::new()

# Scratch dir co-located with the script, never /tmp.
$scratch = Join-Path $PSScriptRoot '.help-probe-scratch'
if (-not (Test-Path -LiteralPath $scratch)) {
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
}

try {
    foreach ($flag in $flags) {
        $tried.Add($flag) | Out-Null
        $stdoutFile = Join-Path $scratch ("probe-{0}.out" -f ([guid]::NewGuid()))
        $stderrFile = Join-Path $scratch ("probe-{0}.err" -f ([guid]::NewGuid()))
        $proc = $null
        try {
            $proc = Start-Process -FilePath $Path -ArgumentList $flag `
                -RedirectStandardOutput $stdoutFile `
                -RedirectStandardError  $stderrFile `
                -WindowStyle Hidden -PassThru -ErrorAction Stop
        } catch {
            if (Test-Path $stdoutFile) { Remove-Item $stdoutFile -ErrorAction Ignore }
            if (Test-Path $stderrFile) { Remove-Item $stderrFile -ErrorAction Ignore }
            continue
        }

        $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            try { $proc.Kill($true) } catch { try { $proc.Kill() } catch {} }
            try { $proc.WaitForExit(2000) | Out-Null } catch {}
            if (Test-Path $stdoutFile) { Remove-Item $stdoutFile -ErrorAction Ignore }
            if (Test-Path $stderrFile) { Remove-Item $stderrFile -ErrorAction Ignore }
            continue
        }

        $exitCode = $proc.ExitCode
        $stdout   = if (Test-Path $stdoutFile) { Get-Content $stdoutFile -Raw -ErrorAction Ignore } else { '' }
        $stderr   = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw -ErrorAction Ignore } else { '' }
        if (-not $stdout) { $stdout = '' }
        if (-not $stderr) { $stderr = '' }
        $combined = ($stdout + $stderr).Trim()
        Remove-Item $stdoutFile -ErrorAction Ignore
        Remove-Item $stderrFile -ErrorAction Ignore

        if ($combined.Length -gt 0) {
            $snippet = $combined.Substring(0, [Math]::Min(200, $combined.Length))
            $snippet = ($snippet -replace '\s+',' ').Trim()
            return [pscustomobject]@{
                Path          = $Path
                Flag          = $flag
                ExitCode      = $exitCode
                OutputSnippet = $snippet
                Success       = $true
                TriedFlags    = $tried.ToArray()
            }
        }
    }

    return [pscustomobject]@{
        Path          = $Path
        Flag          = $null
        ExitCode      = $null
        OutputSnippet = ''
        Success       = $false
        TriedFlags    = $tried.ToArray()
    }
}
finally {
    # Best-effort scratch dir cleanup.
    try {
        if (Test-Path -LiteralPath $scratch) {
            Get-ChildItem -LiteralPath $scratch -File -ErrorAction Ignore |
                Remove-Item -ErrorAction Ignore
            Remove-Item -LiteralPath $scratch -ErrorAction Ignore
        }
    } catch { }
}
