# Capture a package ConfigScript's underlying-tool output (npm/dotnet/Write-Host
# chatter) into the transient live-output channel instead of letting it pile up in
# the scrollback (#352).
#
# Both engines used to run the ConfigScript as `[void](& $p.ConfigScript $p 2>$null)`
# -- output discarded, errors suppressed -- so the AIAgents MCP installer's wall of
# npm/dotnet text hit the host directly and read like a failure on a successful run.
#
# Invoke-ConfigScriptCaptured runs the script with `*>&1` so every stream (including
# Write-Host, which lands on the Information stream in PS5+) flows back through one
# pipeline. Each line is routed to Write-UpdateStatus (transient Write-Progress +
# -Verbose mirror) and appended to a caller-supplied buffer so a failure can flush
# the captured output to the scrollback and to a per-run log file.
#
# NOTE: output written via Out-Host inside a ConfigScript is NOT capturable (it goes
# straight to the host, bypassing every stream). ConfigScripts that want their tool
# output to be transient must therefore use Write-Host, not Out-Host.

function Out-CapturedFailure {
    <#
    .SYNOPSIS
        Flush a failed package's captured ConfigScript output to the host so the
        cause stays visible after the transient pane clears.
    .PARAMETER Name
        The package name (used in the section header).
    .PARAMETER Lines
        The captured output lines to print.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Lines
    )

    if ($Lines.Count -eq 0) { return }
    Write-Host "----- captured output: $Name -----" -ForegroundColor Yellow
    foreach ($line in $Lines) { Write-Host $line }
    Write-Host "----- end captured output: $Name -----" -ForegroundColor Yellow
}

function ConvertTo-CapturedLine {
    <#
    .SYNOPSIS
        Render a single pipeline record captured from a ConfigScript (`*>&1`) as a
        plain display string.
    .DESCRIPTION
        `*>&1` yields a mix of raw objects and stream records (Warning / Error /
        Verbose / Debug / Information). This normalizes any of them to a single
        line of text for the transient pane and the recoverable buffer. Returns
        `$null` for a record that has no meaningful text so the caller can skip it.
    .PARAMETER Record
        One item emitted by `& $ConfigScript $pkg *>&1`.
    .OUTPUTS
        System.String (or $null).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()]$Record
    )

    if ($null -eq $Record) { return $null }

    $text = switch ($Record) {
        { $_ -is [System.Management.Automation.WarningRecord] }     { $_.Message; break }
        { $_ -is [System.Management.Automation.ErrorRecord] }       { $_.ToString(); break }
        { $_ -is [System.Management.Automation.VerboseRecord] }     { $_.Message; break }
        { $_ -is [System.Management.Automation.DebugRecord] }       { $_.Message; break }
        { $_ -is [System.Management.Automation.InformationRecord] } { $_.ToString(); break }
        default                                                     { "$Record" }
    }

    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function Invoke-ConfigScriptCaptured {
    <#
    .SYNOPSIS
        Run a package ConfigScript, routing its output to the transient live channel
        and a recoverable buffer instead of the scrollback.
    .DESCRIPTION
        Streams `& $ConfigScript $Package *>&1` lazily: every line is appended to
        $Buffer (so a failure can flush it) and shown via Write-UpdateStatus
        (transient + -Verbose mirror). Genuine warnings are re-emitted via
        Write-Warning so they survive past the auto-clearing pane. Captured errors
        are kept in the buffer only -- they are NOT re-emitted as errors, so a
        non-terminating ConfigScript error cannot trip a caller's
        $ErrorActionPreference='Stop' and abort the package sweep. A terminating
        throw propagates to the caller (which records the package Failed); the lines
        captured before the throw remain in $Buffer.

        Nothing is written to the success (object) stream, so the cmdlet's pipeline
        output stays clean -- identical to the old `[void](... 2>$null)` contract.
    .PARAMETER ConfigScript
        The package's ConfigScript scriptblock.
    .PARAMETER Package
        The [Package] passed as the script's single argument.
    .PARAMETER Buffer
        A caller-owned list that receives each captured line (for failure flush/log).
    .PARAMETER Activity
        Progress activity label (e.g. 'Update-Package' or 'Install-Package').
    .PARAMETER PercentComplete
        Optional 0-100 progress value; omit (-1) when none applies.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ConfigScript,
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Buffer,
        [string]$Activity = 'Update-Package',
        [int]$PercentComplete = -1
    )

    & $ConfigScript $Package *>&1 | ForEach-Object {
        $record = $_
        $line = ConvertTo-CapturedLine $record
        if ($null -ne $line) {
            [void]$Buffer.Add($line)
            $statusArgs = @{ Status = $line; Activity = $Activity }
            if ($PercentComplete -ge 0) { $statusArgs['PercentComplete'] = $PercentComplete }
            Write-UpdateStatus @statusArgs
        }
        if ($record -is [System.Management.Automation.WarningRecord]) {
            Write-Warning $record.Message
        }
    }
}

function Get-FailureLogFileName {
    <#
    .SYNOPSIS
        Build the per-run failure-log file name.
    .DESCRIPTION
        Returns `ScoopBucket-<Verb>-Package-<yyyyMMdd-HHmmss>-failures.log`. The
        timestamp (run start) keeps names sortable and collision-free.
    .PARAMETER Verb
        'Update' or 'Install' (reflecting the cmdlet that produced the failures).
    .PARAMETER Timestamp
        The run-start time used in the name. Defaults to now.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('Update', 'Install')][string]$Verb,
        [datetime]$Timestamp = (Get-Date)
    )
    return "ScoopBucket-$Verb-Package-$($Timestamp.ToString('yyyyMMdd-HHmmss'))-failures.log"
}

function Get-FailureLogPath {
    <#
    .SYNOPSIS
        Resolve the full path for the per-run failure log, preferring the current
        directory and falling back when it is not writable.
    .DESCRIPTION
        Logging must never break a run. The preferred directory (the current
        directory) is probed by writing and deleting a tiny test file; if that
        fails (read-only location, permission denied), the fallback directory
        ($env:TEMP) is used instead.
    .PARAMETER FileName
        The log file name (see Get-FailureLogFileName).
    .PARAMETER PreferredDirectory
        First-choice directory (typically the caller's current directory).
    .PARAMETER FallbackDirectory
        Used when PreferredDirectory is not writable.
    .OUTPUTS
        System.String -- the full path under whichever directory is writable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$PreferredDirectory,
        [Parameter(Mandatory)][string]$FallbackDirectory
    )

    $dir = if (Test-DirectoryWritable -Path $PreferredDirectory) {
        $PreferredDirectory
    } else {
        $FallbackDirectory
    }
    return (Join-Path $dir $FileName)
}

function Test-DirectoryWritable {
    <#
    .SYNOPSIS
        Return $true when a tiny probe file can be created (and removed) in $Path.
    .PARAMETER Path
        Directory to probe.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $probe = Join-Path $Path ".sb-write-probe-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Write-FailureLog {
    <#
    .SYNOPSIS
        Write the per-run failure log (run header + each failed package's full
        captured output) as UTF-8 without a BOM.
    .PARAMETER Path
        Destination file (see Get-FailureLogPath).
    .PARAMETER Verb
        'Update' or 'Install'.
    .PARAMETER Failures
        One object per failed package with .Name, .Reason and .Output (the full
        captured ConfigScript text).
    .OUTPUTS
        System.String -- the path written.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Update', 'Install')][string]$Verb,
        [Parameter(Mandatory)][object[]]$Failures
    )

    $nl = [Environment]::NewLine
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("ScoopBucket $Verb-Package failure log")
    [void]$sb.AppendLine("Generated: $((Get-Date).ToString('u')) (local $((Get-Date).ToString('s')))")
    [void]$sb.AppendLine("Machine:   $env:COMPUTERNAME")
    [void]$sb.AppendLine("Failures:  $($Failures.Count)")
    [void]$sb.AppendLine(('=' * 72))

    foreach ($f in $Failures) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("### $($f.Name)")
        if ($f.Reason) { [void]$sb.AppendLine("Reason: $($f.Reason)") }
        [void]$sb.AppendLine('--- captured output ---')
        $out = if ($null -ne $f.Output) { [string]$f.Output } else { '' }
        if ([string]::IsNullOrWhiteSpace($out)) {
            [void]$sb.AppendLine('(no captured output)')
        } else {
            [void]$sb.AppendLine($out)
        }
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, ($sb.ToString() -replace "`r?`n", $nl), $utf8NoBom)
    return $Path
}
