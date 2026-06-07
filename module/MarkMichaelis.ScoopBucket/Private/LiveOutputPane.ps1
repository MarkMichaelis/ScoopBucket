# Host-adaptive "live output" pane for the package commands (#354).
#
# Thrust A (#352) routed package ConfigScript output through Write-UpdateStatus,
# which renders a single transient line via Write-Progress. Style A (#361) renders,
# on a capable interactive console, a bottom-anchored STICKY status bar via a VT
# scroll region (DECSTBM): the package log scrolls normally ABOVE the bar and stays
# in scrollback (selectable / copy-paste-able), while only the pinned status bar is
# transient and is torn down on completion. Everywhere the host cannot drive the
# scroll-region cursor math (VS Code, CI, redirected, ISE, a non-VT host, or a window
# too short for a bar plus a usable log) it degrades to the robust single-line
# Write-Progress region (or, when progress is silenced, to a verbose-only mirror).
# $env:SCOOPBUCKET_LIVE_PANE is an off-switch: a falsy value (0/false/no/off/single)
# forces the single-line region even on a capable console (#356/#361).
#
# All host-detection and frame-building logic is pure (returns a mode enum / strings)
# so it is fully unit-testable without a live console. Only Write-LivePane performs
# the imperative cursor writes, and it is gated by Resolve-LiveOutputMode -- which
# only resolves Sticky on a console that can actually render it.
#
# PORTABILITY (#361): the renderer is intentionally ScoopBucket-agnostic -- the pure
# frame builders and Write-LivePane core take only primitives (strings, ints, host
# facts) and reference no [Package]/bundle/Update-Package types, so this single file
# can later be lifted verbatim into the IntelliSDLC.ai upstream repo as a generic
# console-overlay utility. Write-UpdateStatus stays a thin ScoopBucket adapter.

# Minimum console height (rows) required to host a sticky status bar plus a usable
# scrolling log; shorter windows degrade to the single-line region.
$script:StickyMinHeight = 6

function Resolve-LiveOutputMode {
    <#
    .SYNOPSIS
        Decide how the live-output pane should render on the current host.
    .DESCRIPTION
        Returns one of 'Sticky', 'Single', or 'Off' from host facts. The bottom-anchored
        sticky scroll-region bar is the DEFAULT for a genuinely interactive, VT-capable,
        non-VS-Code, non-CI, non-redirected, non-ISE console that is tall enough to host
        a pinned bar plus a usable log -- those are exactly the hosts whose scroll-region
        cursor math the renderer can drive safely. Every other host degrades to the robust
        single-line Write-Progress region. $env:SCOOPBUCKET_LIVE_PANE is an
        override/off-switch: a falsy value (0/false/no/off/single, case-insensitive)
        forces Single even on a capable console. A silenced progress preference
        resolves to Off (verbose-only). All facts are parameters (defaulted from the
        environment) so every host signature can be unit-tested deterministically.
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
    .PARAMETER LivePaneOverride
        Value of $env:SCOOPBUCKET_LIVE_PANE. A falsy value (0/false/no/off/single,
        case-insensitive) forces the safe single-line region even on a capable host;
        any other value (including empty) leaves the capability-based default in
        effect.
    .PARAMETER WindowHeight
        Console window height in rows ([Console]::WindowHeight). Resolved live when
        not supplied. A window too short to host a pinned status bar plus a usable
        scrolling log degrades to Single.
    .OUTPUTS
        System.String -- 'Sticky' | 'Single' | 'Off'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$TermProgram = $env:TERM_PROGRAM,
        [string]$Ci = $env:CI,
        [Nullable[bool]]$OutputRedirected,
        [string]$HostName = $Host.Name,
        [Nullable[bool]]$SupportsVirtualTerminal,
        [string]$ProgressPreferenceValue = "$ProgressPreference",
        [string]$LivePaneOverride = $env:SCOOPBUCKET_LIVE_PANE,
        [Nullable[int]]$WindowHeight
    )

    if ($null -eq $OutputRedirected) {
        try { $OutputRedirected = [Console]::IsOutputRedirected } catch { $OutputRedirected = $false }
    }
    if ($null -eq $SupportsVirtualTerminal) {
        try { $SupportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $SupportsVirtualTerminal = $false }
    }
    if ($null -eq $WindowHeight) {
        try { $WindowHeight = [Console]::WindowHeight } catch { $WindowHeight = 0 }
    }

    if ($ProgressPreferenceValue -eq 'SilentlyContinue') { return 'Off' }

    # Explicit off-switch (#361): a falsy override forces the safe single-line region
    # even on a fully capable console.
    if ($LivePaneOverride -match '^\s*(?i:0|false|no|off|single)\s*$') { return 'Single' }

    # Capability gates: these hosts cannot drive the scroll-region cursor math, so the
    # sticky default degrades to the robust single-line region.
    if (-not [string]::IsNullOrEmpty($Ci))                { return 'Single' }
    if ($OutputRedirected)                                { return 'Single' }
    if ($TermProgram -eq 'vscode')                        { return 'Single' }
    if ($HostName -like '*ISE*')                          { return 'Single' }
    if (-not $SupportsVirtualTerminal)                    { return 'Single' }
    # A window too short for a pinned bar plus a usable log degrades to Single.
    if ($WindowHeight -gt 0 -and $WindowHeight -lt $script:StickyMinHeight) { return 'Single' }
    return 'Sticky'
}

function Get-LivePaneFrame {
    <#
    .SYNOPSIS
        Build the ANSI repaint string for the multiline pane and report how many
        lines it now occupies.
    .DESCRIPTION
        Shows the last MaxLines of the supplied buffer. Each incoming entry is first
        split on embedded newlines so one physical row maps to exactly one drawn line
        (npm/dotnet emit multi-line records), and -- when Width > 0 -- each row is
        truncated to Width so it can never wrap. Both are required for the reported
        LineCount to equal the physical rows drawn; otherwise the next frame's
        cursor-up math overwrites the wrong rows (#356). When a previous frame is on
        screen (PreviousLineCount > 0), the returned text first moves the cursor to
        the top of that block and clears to the end of the display, then writes the
        current tail (lines joined by newline, no trailing newline -- the cursor is
        left on the last line so the next frame's PreviousLineCount is the tail
        count). Pure: returns the text + line count, writes nothing.
    .PARAMETER Lines
        The full rolling buffer; only the last MaxLines (after newline-splitting) are
        drawn.
    .PARAMETER PreviousLineCount
        Lines drawn by the previous frame (0 for the first paint).
    .PARAMETER MaxLines
        Maximum pane height.
    .PARAMETER Width
        Maximum drawn width per line; 0 (default) disables truncation. Lines longer
        than Width are clipped so they occupy a single physical row.
    .OUTPUTS
        PSCustomObject with Text (string) and LineCount (int).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]]$Lines = @(),
        [int]$PreviousLineCount = 0,
        [ValidateRange(1, 100)][int]$MaxLines = 5,
        [int]$Width = 0
    )

    $esc = [char]27

    # Split embedded newlines so each entry is exactly one physical row, then keep
    # the most recent MaxLines, then clip to Width so nothing wraps.
    $physical = foreach ($line in @($Lines | Where-Object { $null -ne $_ })) {
        $line -split "`r?`n"
    }
    $tail = @($physical | Select-Object -Last $MaxLines)
    if ($Width -gt 0) {
        $tail = @($tail | ForEach-Object {
            if ($_.Length -gt $Width) { $_.Substring(0, $Width) } else { $_ }
        })
    }

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

function Get-StickyRegionEnter {
    <#
    .SYNOPSIS
        Build the VT sequence that opens a bottom-anchored sticky scroll region.
    .DESCRIPTION
        Sets the DECSTBM scroll region (ESC[<top>;<bottom>r) to rows 1..(Height-BarRows)
        so the bottom BarRows are frozen as a pinned status bar, then parks the cursor on
        the last scrolling row so subsequent log writes scroll ABOVE the bar and persist
        in scrollback. Pure: returns the string, writes nothing. ScoopBucket-agnostic.
    .PARAMETER Height
        Console window height in rows.
    .PARAMETER BarRows
        Number of rows reserved at the bottom for the status bar (default 1).
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][int]$Height,
        [int]$BarRows = 1
    )
    $esc = [char]27
    $bottom = [Math]::Max(1, $Height - $BarRows)
    return "$esc[1;${bottom}r$esc[${bottom};1H"
}

function Get-StickyStatusFrame {
    <#
    .SYNOPSIS
        Build the VT sequence that paints the pinned status bar without disturbing the
        scrolling log cursor.
    .DESCRIPTION
        Saves the cursor (ESC7), moves to the first bar row, clears the line, renders the
        status inverse (ESC[7m..ESC[0m) clipped to Width so it never wraps, then restores
        the cursor (ESC8) back into the scrolling region. Pure. ScoopBucket-agnostic.
    .PARAMETER Status
        Status text for the bar.
    .PARAMETER Height
        Console window height in rows.
    .PARAMETER BarRows
        Rows reserved for the bar (default 1).
    .PARAMETER Width
        Maximum drawn width; the status is clipped to this so the bar never wraps.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Status = '',
        [Parameter(Mandatory)][int]$Height,
        [int]$BarRows = 1,
        [int]$Width = 0
    )
    $esc = [char]27
    $barRow = [Math]::Max(1, $Height - $BarRows + 1)
    $text = $Status
    if ($Width -gt 0 -and $text.Length -gt $Width) { $text = $text.Substring(0, $Width) }
    return "$esc`7$esc[${barRow};1H$esc[2K$esc[7m$text$esc[0m$esc`8"
}

function Get-StickyLogLine {
    <#
    .SYNOPSIS
        Build the persistent log text written into the scrolling region above the bar.
    .DESCRIPTION
        Splits embedded newlines so each record maps to exactly one physical row, clips
        each row to Width so nothing wraps, and joins them with newlines. The very first
        line is written in place (the cursor is already parked on the last scrolling row);
        every later line is prefixed with a newline so the region scrolls up by one. The
        log is intentionally left in scrollback (copy/paste-able). Pure. ScoopBucket-
        agnostic.
    .PARAMETER Text
        The log record (may contain embedded newlines).
    .PARAMETER Width
        Maximum drawn width per row; 0 disables clipping.
    .PARAMETER IsFirst
        $true for the first log line of the region (no leading newline).
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Text = '',
        [int]$Width = 0,
        [bool]$IsFirst = $false
    )
    $rows = @($Text -split "`r?`n")
    if ($Width -gt 0) {
        $rows = @($rows | ForEach-Object {
            if ($_.Length -gt $Width) { $_.Substring(0, $Width) } else { $_ }
        })
    }
    $body = $rows -join "`n"
    if ($IsFirst) { return $body }
    return "`n$body"
}

function Get-StickyRegionLeave {
    <#
    .SYNOPSIS
        Build the VT sequence that tears the sticky region down on completion.
    .DESCRIPTION
        Resets the scroll region to the full window (ESC[r), moves to the first bar row,
        and clears to the end of the display so the transient status bar is wiped while
        the scrolled log above it remains in scrollback. The cursor is left where the
        bar was so the caller's summary table prints directly below the persisted log.
        Pure. ScoopBucket-agnostic.
    .PARAMETER Height
        Console window height in rows.
    .PARAMETER BarRows
        Rows that were reserved for the bar (default 1).
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][int]$Height,
        [int]$BarRows = 1
    )
    $esc = [char]27
    $barRow = [Math]::Max(1, $Height - $BarRows + 1)
    return "$esc[r$esc[${barRow};1H$esc[0J"
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
          * Sticky    -- on first call, open a bottom-anchored VT scroll region and
                         pin a status bar; each call scrolls the status into the
                         persistent log above the bar and refreshes the bar;
          * Multiline -- append to the rolling buffer and repaint the ANSI pane;
          * Single    -- delegate to Write-StatusProgress (Write-Progress region);
          * Off       -- verbose-only.
        -Completed tears the renderer down (reset the scroll region / erase the
        multiline pane / clear the progress line) and resets the pane state. The Sticky
        teardown is also safe to call from a finally on an aborted run.
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
        [ValidateSet('Sticky', 'Multiline', 'Single', 'Off')][string]$Mode
    )

    if (-not $Mode) { $Mode = Resolve-LiveOutputMode }

    if ($Completed) {
        # Tear down an open sticky region whenever one is active, regardless of what
        # Mode now resolves to -- this guarantees the VT scroll region is always reset
        # even if host facts shifted mid-run (otherwise a stale region could leak).
        if ($script:StickyActive) {
            $height = 0
            try { $height = [Console]::WindowHeight } catch { $height = 0 }
            if ($height -gt 0) {
                [Console]::Out.Write((Get-StickyRegionLeave -Height $height -BarRows $script:StickyBarRows))
            }
            $script:StickyActive = $false
            $script:StickyStarted = $false
            return
        }
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
        'Sticky' {
            $height = 0
            try { $height = [Console]::WindowHeight } catch { $height = 0 }
            $width = 0
            try { $width = [Console]::WindowWidth - 1 } catch { $width = 0 }
            if ($width -lt 10) { $width = 0 }
            if ($script:StickyBarRows -lt 1) { $script:StickyBarRows = 1 }

            if (-not $script:StickyActive) {
                if ($height -gt 0) {
                    [Console]::Out.Write((Get-StickyRegionEnter -Height $height -BarRows $script:StickyBarRows))
                }
                $script:StickyActive = $true
                $script:StickyStarted = $false
            }

            # Scroll the status into the persistent (copy/paste-able) log above the bar.
            [Console]::Out.Write((Get-StickyLogLine -Text $Status -Width $width -IsFirst (-not $script:StickyStarted)))
            $script:StickyStarted = $true

            # Refresh the pinned bar with the latest status without moving the log cursor.
            if ($height -gt 0) {
                [Console]::Out.Write((Get-StickyStatusFrame -Status $Status -Height $height -BarRows $script:StickyBarRows -Width $width))
            }
        }
        'Multiline' {
            if (-not $script:LivePaneBuffer) {
                $script:LivePaneBuffer = New-Object System.Collections.Generic.List[string]
            }
            [void]$script:LivePaneBuffer.Add($Status)
            $width = 0
            try { $width = [Console]::WindowWidth - 1 } catch { $width = 0 }
            if ($width -lt 10) { $width = 0 }
            $frame = Get-LivePaneFrame -Lines $script:LivePaneBuffer -PreviousLineCount $script:LivePaneLineCount -MaxLines $MaxLines -Width $width
            [Console]::Out.Write($frame.Text)
            $script:LivePaneLineCount = $frame.LineCount
        }
    }
}
