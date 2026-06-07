# Host-adaptive transient "live output" pane for the package commands (#354).
#
# Thrust A (#352) routed package ConfigScript output through Write-UpdateStatus,
# which renders a single transient line via Write-Progress. This adds a multiline
# pane that shows a rolling tail of the most recent live-output lines and clears on
# completion -- on hosts that can repaint with ANSI cursor moves. Everywhere else it
# degrades to the existing single-line Write-Progress region, or (when progress is
# silenced) to a verbose-only mirror.
#
# All host-detection and frame-building logic is pure (returns a mode enum / strings)
# so it is fully unit-testable without a live console. Only Write-LivePane performs
# the imperative cursor writes, and it is gated by Resolve-LiveOutputMode -- when in
# any doubt the mode resolves to Single, never Multiline.

function Resolve-LiveOutputMode {
    <#
    .SYNOPSIS
        Decide how the live-output pane should render on the current host.
    .DESCRIPTION
        Returns one of 'Multiline', 'Single', or 'Off' from host facts. Multiline is
        chosen only for a genuinely interactive, VT-capable console that is not VS
        Code, not CI, not redirected, and not the ISE. Any uncertainty resolves to
        the safe single-line region; a silenced progress preference resolves to Off
        (verbose-only). All facts are parameters (defaulted from the environment) so
        every host signature can be unit-tested deterministically.
    .PARAMETER TermProgram
        Value of $env:TERM_PROGRAM (e.g. 'vscode').
    .PARAMETER Ci
        Value of $env:CI; any non-empty value forces Single.
    .PARAMETER OutputRedirected
        Whether stdout is redirected ([Console]::IsOutputRedirected). Resolved live
        when not supplied.
    .PARAMETER HostName
        $Host.Name; an ISE host forces Single.
    .PARAMETER SupportsVirtualTerminal
        Whether the host UI supports virtual-terminal sequences. Resolved live when
        not supplied.
    .PARAMETER ProgressPreferenceValue
        String form of $ProgressPreference; 'SilentlyContinue' forces Off.
    .OUTPUTS
        System.String -- 'Multiline' | 'Single' | 'Off'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$TermProgram = $env:TERM_PROGRAM,
        [string]$Ci = $env:CI,
        [Nullable[bool]]$OutputRedirected,
        [string]$HostName = $Host.Name,
        [Nullable[bool]]$SupportsVirtualTerminal,
        [string]$ProgressPreferenceValue = "$ProgressPreference"
    )

    if ($null -eq $OutputRedirected) {
        try { $OutputRedirected = [Console]::IsOutputRedirected } catch { $OutputRedirected = $false }
    }
    if ($null -eq $SupportsVirtualTerminal) {
        try { $SupportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $SupportsVirtualTerminal = $false }
    }

    if ($ProgressPreferenceValue -eq 'SilentlyContinue') { return 'Off' }
    if (-not [string]::IsNullOrEmpty($Ci))                { return 'Single' }
    if ($OutputRedirected)                                { return 'Single' }
    if ($TermProgram -eq 'vscode')                        { return 'Single' }
    if ($HostName -like '*ISE*')                          { return 'Single' }
    if (-not $SupportsVirtualTerminal)                    { return 'Single' }
    return 'Multiline'
}

function Get-LivePaneFrame {
    <#
    .SYNOPSIS
        Build the ANSI repaint string for the multiline pane and report how many
        lines it now occupies.
    .DESCRIPTION
        Shows the last MaxLines of the supplied buffer. When a previous frame is on
        screen (PreviousLineCount > 0), the returned text first moves the cursor to
        the top of that block and clears to the end of the display, then writes the
        current tail (lines joined by newline, no trailing newline -- the cursor is
        left on the last line so the next frame's PreviousLineCount is the tail
        count). Pure: returns the text + line count, writes nothing.
    .PARAMETER Lines
        The full rolling buffer; only the last MaxLines are drawn.
    .PARAMETER PreviousLineCount
        Lines drawn by the previous frame (0 for the first paint).
    .PARAMETER MaxLines
        Maximum pane height.
    .OUTPUTS
        PSCustomObject with Text (string) and LineCount (int).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]]$Lines = @(),
        [int]$PreviousLineCount = 0,
        [ValidateRange(1, 100)][int]$MaxLines = 5
    )

    $esc = [char]27
    $tail = @($Lines | Where-Object { $null -ne $_ } | Select-Object -Last $MaxLines)

    $reset = ''
    if ($PreviousLineCount -gt 0) {
        $up = [Math]::Max(0, $PreviousLineCount - 1)
        $reset = "$esc[${up}F$esc[0J"
    }

    return [pscustomobject]@{
        Text      = $reset + ($tail -join "`n")
        LineCount = $tail.Count
    }
}

function Get-LivePaneClear {
    <#
    .SYNOPSIS
        Build the ANSI string that erases the multiline pane on completion.
    .DESCRIPTION
        Moves the cursor to the top of the drawn block and clears to the end of the
        display, leaving the cursor where the pane began so the final table prints in
        its place. Returns '' when nothing was drawn. Pure.
    .PARAMETER PreviousLineCount
        Lines currently drawn by the pane.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$PreviousLineCount = 0)

    if ($PreviousLineCount -le 0) { return '' }
    $esc = [char]27
    $up = [Math]::Max(0, $PreviousLineCount - 1)
    return "$esc[${up}F$esc[0J"
}

function Write-StatusProgress {
    <#
    .SYNOPSIS
        Render a single transient status line via Write-Progress (the Single-mode
        renderer extracted from the original #276 Write-UpdateStatus body).
    .PARAMETER Status
        Status text; omit with -Completed to tear the line down.
    .PARAMETER Activity
        Progress activity label.
    .PARAMETER Id
        Progress record id.
    .PARAMETER ParentId
        Parent progress record id (>= 0 to set).
    .PARAMETER PercentComplete
        0-100; omit (-1) when none applies.
    .PARAMETER Completed
        Clear the progress line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Status,
        [string]$Activity = 'Update-Package',
        [int]$Id = 1,
        [int]$ParentId = -1,
        [int]$PercentComplete = -1,
        [switch]$Completed
    )

    if ($Completed) {
        Write-Progress -Activity $Activity -Id $Id -Completed
        return
    }
    if (-not $Status) { return }

    $progressArgs = @{ Activity = $Activity; Status = $Status; Id = $Id }
    if ($ParentId -ge 0)        { $progressArgs['ParentId']        = $ParentId }
    if ($PercentComplete -ge 0) { $progressArgs['PercentComplete'] = [Math]::Min(100, [Math]::Max(0, $PercentComplete)) }
    Write-Progress @progressArgs
}

function Write-LivePane {
    <#
    .SYNOPSIS
        Render a live-output status line through the host-appropriate renderer and
        keep the module-scoped multiline pane state.
    .DESCRIPTION
        Mirrors every status to Write-Verbose (recoverable in all modes), then:
          * Multiline -- append to the rolling buffer and repaint the ANSI pane;
          * Single    -- delegate to Write-StatusProgress (Write-Progress region);
          * Off       -- verbose-only.
        -Completed tears the renderer down (erase the multiline pane / clear the
        progress line) and resets the pane state.
    .PARAMETER Status
        The status text.
    .PARAMETER Activity
        Progress / pane activity label.
    .PARAMETER Id
        Progress record id (Single mode).
    .PARAMETER ParentId
        Parent progress record id (Single mode).
    .PARAMETER PercentComplete
        0-100 (Single mode); omit (-1) when none applies.
    .PARAMETER MaxLines
        Multiline pane height.
    .PARAMETER Completed
        Tear the renderer down and reset pane state.
    .PARAMETER Mode
        Force a renderer mode (testing/override); defaults to Resolve-LiveOutputMode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Status,
        [string]$Activity = 'Update-Package',
        [int]$Id = 1,
        [int]$ParentId = -1,
        [int]$PercentComplete = -1,
        [ValidateRange(1, 100)][int]$MaxLines = 5,
        [switch]$Completed,
        [ValidateSet('Multiline', 'Single', 'Off')][string]$Mode
    )

    if (-not $Mode) { $Mode = Resolve-LiveOutputMode }

    if ($Completed) {
        if ($Mode -eq 'Multiline') {
            if ($script:LivePaneLineCount -gt 0) {
                [Console]::Out.Write((Get-LivePaneClear -PreviousLineCount $script:LivePaneLineCount))
            }
        } else {
            Write-StatusProgress -Activity $Activity -Id $Id -Completed
        }
        $script:LivePaneLineCount = 0
        if ($script:LivePaneBuffer) { $script:LivePaneBuffer.Clear() }
        return
    }

    if (-not $Status) { return }

    Write-Verbose $Status

    switch ($Mode) {
        'Off' { return }
        'Single' {
            $progressArgs = @{ Status = $Status; Activity = $Activity; Id = $Id }
            if ($ParentId -ge 0)        { $progressArgs['ParentId']        = $ParentId }
            if ($PercentComplete -ge 0) { $progressArgs['PercentComplete'] = $PercentComplete }
            Write-StatusProgress @progressArgs
        }
        'Multiline' {
            if (-not $script:LivePaneBuffer) {
                $script:LivePaneBuffer = New-Object System.Collections.Generic.List[string]
            }
            [void]$script:LivePaneBuffer.Add($Status)
            $frame = Get-LivePaneFrame -Lines $script:LivePaneBuffer -PreviousLineCount $script:LivePaneLineCount -MaxLines $MaxLines
            [Console]::Out.Write($frame.Text)
            $script:LivePaneLineCount = $frame.LineCount
        }
    }
}
