<#
.SYNOPSIS
    Light-suite Pester coverage for the host-adaptive live-output pane helpers
    (#354).

.DESCRIPTION
    The multiline pane is the portability risk, so its decision logic and frame
    strings are pure and pinned here:

      * Resolve-LiveOutputMode defaults to the multiline pane on any capable,
        VT-capable, non-VS-Code, non-CI, non-redirected, non-ISE interactive console,
        and degrades to the single-line Write-Progress region everywhere the host
        cannot drive it. $env:SCOOPBUCKET_LIVE_PANE is an override/off-switch: a
        falsy value (0/false/no/off/single) forces Single even on a capable console; a
        silenced progress preference is Off.
      * Get-LivePaneFrame / Get-LivePaneClear emit the exact cursor-move + clear
        sequences, split embedded newlines, truncate to a supplied width, and
        account for the drawn line count.
      * Write-LivePane mirrors to verbose in every mode and maintains the pane's
        line-count state across calls / teardown.
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path $PSScriptRoot '..\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force
    $script:mod = Get-Module MarkMichaelis.ScoopBucket
    $script:ESC = [char]27
}

Describe 'Resolve-LiveOutputMode' -Tag 'Light','Module' {
    It 'returns Off when the progress preference is silenced' {
        $m = & $script:mod {
            Resolve-LiveOutputMode -ProgressPreferenceValue 'SilentlyContinue' `
                -SupportsVirtualTerminal $true -OutputRedirected $false
        }
        $m | Should -Be 'Off'
    }

    It 'returns Single under CI' {
        $m = & $script:mod {
            Resolve-LiveOutputMode -Ci 'true' -SupportsVirtualTerminal $true -OutputRedirected $false -ProgressPreferenceValue 'Continue'
        }
        $m | Should -Be 'Single'
    }

    It 'returns Single when output is redirected' {
        $m = & $script:mod {
            Resolve-LiveOutputMode -Ci '' -OutputRedirected $true -SupportsVirtualTerminal $true -ProgressPreferenceValue 'Continue'
        }
        $m | Should -Be 'Single'
    }

    It 'returns Single inside the VS Code integrated terminal' {
        $m = & $script:mod {
            Resolve-LiveOutputMode -TermProgram 'vscode' -Ci '' -OutputRedirected $false -SupportsVirtualTerminal $true -ProgressPreferenceValue 'Continue'
        }
        $m | Should -Be 'Single'
    }

    It 'returns Single in the ISE host' {
        $m = & $script:mod {
            Resolve-LiveOutputMode -HostName 'Windows PowerShell ISE Host' -Ci '' -OutputRedirected $false -SupportsVirtualTerminal $true -ProgressPreferenceValue 'Continue'
        }
        $m | Should -Be 'Single'
    }

    It 'returns Single when the host lacks virtual-terminal support' {
        $m = & $script:mod {
            Resolve-LiveOutputMode -Ci '' -OutputRedirected $false -SupportsVirtualTerminal $false -ProgressPreferenceValue 'Continue'
        }
        $m | Should -Be 'Single'
    }

    It 'returns Sticky by default for a capable interactive console (no override)' {
        $m = & $script:mod {
            Resolve-LiveOutputMode -TermProgram 'WindowsTerminal' -Ci '' -OutputRedirected $false `
                -HostName 'ConsoleHost' -SupportsVirtualTerminal $true -ProgressPreferenceValue 'Continue' `
                -LivePaneOverride '' -WindowHeight 30
        }
        $m | Should -Be 'Sticky'
    }

    It 'returns Single for a capable interactive console when the override forces it off' {
        foreach ($off in '0', 'false', 'no', 'off', 'single') {
            $m = & $script:mod {
                param($off)
                Resolve-LiveOutputMode -TermProgram 'WindowsTerminal' -Ci '' -OutputRedirected $false `
                    -HostName 'ConsoleHost' -SupportsVirtualTerminal $true -ProgressPreferenceValue 'Continue' `
                    -LivePaneOverride $off -WindowHeight 30
            } $off
            $m | Should -Be 'Single' -Because "override '$off' must force the single-line region"
        }
    }

    It 'still returns Sticky for a capable console when the override explicitly requests it' {
        $m = & $script:mod {
            Resolve-LiveOutputMode -TermProgram 'WindowsTerminal' -Ci '' -OutputRedirected $false `
                -HostName 'ConsoleHost' -SupportsVirtualTerminal $true -ProgressPreferenceValue 'Continue' `
                -LivePaneOverride 'multiline' -WindowHeight 30
        }
        $m | Should -Be 'Sticky'
    }

    It 'falls back to Single on a capable console when the window is too short for a sticky bar' {
        $m = & $script:mod {
            Resolve-LiveOutputMode -TermProgram 'WindowsTerminal' -Ci '' -OutputRedirected $false `
                -HostName 'ConsoleHost' -SupportsVirtualTerminal $true -ProgressPreferenceValue 'Continue' `
                -LivePaneOverride '' -WindowHeight 4
        }
        $m | Should -Be 'Single'
    }

    It 'keeps Single when the host is not capable (redirected) even with no override' {
        $m = & $script:mod {
            Resolve-LiveOutputMode -Ci '' -OutputRedirected $true -SupportsVirtualTerminal $true `
                -ProgressPreferenceValue 'Continue' -LivePaneOverride '' -WindowHeight 30
        }
        $m | Should -Be 'Single'
    }

    It 'does not read the console window height once a cheap gate has chosen Single' {
        # On a headless host the [Console]::WindowHeight getter raises a
        # non-terminating "handle is invalid" error that leaks into a caller's
        # -ErrorVariable. The cheap, non-throwing gates (CI / redirected / vscode /
        # ISE / no-VT) must therefore short-circuit BEFORE the height is probed.
        foreach ($case in @(
                @{ Name = 'CI';         Args = @{ Ci = 'true'; OutputRedirected = $false; SupportsVirtualTerminal = $true } }
                @{ Name = 'redirected'; Args = @{ Ci = '';     OutputRedirected = $true;  SupportsVirtualTerminal = $true } }
                @{ Name = 'vscode';     Args = @{ Ci = '';     OutputRedirected = $false; SupportsVirtualTerminal = $true; TermProgram = 'vscode' } }
                @{ Name = 'no-VT';      Args = @{ Ci = '';     OutputRedirected = $false; SupportsVirtualTerminal = $false } }
            )) {
            Mock -ModuleName MarkMichaelis.ScoopBucket Get-ConsoleWindowHeight { 30 }
            $splat = $case.Args
            $m = & $script:mod {
                param($splat)
                Resolve-LiveOutputMode @splat -HostName 'ConsoleHost' -ProgressPreferenceValue 'Continue' -LivePaneOverride ''
            } $splat
            $m | Should -Be 'Single' -Because "the $($case.Name) gate must force Single"
            Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Get-ConsoleWindowHeight -Times 0 -Exactly `
                -Because "the $($case.Name) gate must short-circuit before the console handle is touched"
        }
    }

    It 'reads the console window height only when no cheaper gate short-circuits' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-ConsoleWindowHeight { 30 }
        $m = & $script:mod {
            Resolve-LiveOutputMode -TermProgram 'WindowsTerminal' -Ci '' -OutputRedirected $false `
                -HostName 'ConsoleHost' -SupportsVirtualTerminal $true -ProgressPreferenceValue 'Continue' `
                -LivePaneOverride ''
        }
        $m | Should -Be 'Sticky'
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket Get-ConsoleWindowHeight -Times 1 -Exactly
    }
}

Describe 'Get-LivePaneFrame' -Tag 'Light','Module' {
    It 'draws all lines and reports the count on the first paint (no cursor move)' {
        $f = & $script:mod { Get-LivePaneFrame -Lines @('a', 'b') -PreviousLineCount 0 }
        $f.Text | Should -Be "a`nb"
        $f.LineCount | Should -Be 2
    }

    It 'prefixes a cursor-up + clear-to-end sequence when repainting over a prior frame' {
        $f = & $script:mod { Get-LivePaneFrame -Lines @('a', 'b', 'c') -PreviousLineCount 3 }
        # 3 lines drawn => move up 2 to the top of the block, then clear to end.
        $expectedReset = "$($script:ESC)[2F$($script:ESC)[0J"
        $f.Text | Should -Be ($expectedReset + "a`nb`nc")
        $f.LineCount | Should -Be 3
    }

    It 'caps the pane to MaxLines (keeps the most recent lines)' {
        $f = & $script:mod { Get-LivePaneFrame -Lines @('1', '2', '3', '4', '5', '6') -PreviousLineCount 0 -MaxLines 3 }
        $f.Text | Should -Be "4`n5`n6"
        $f.LineCount | Should -Be 3
    }

    It 'splits an embedded-newline record into separate physical rows' {
        # A single captured record carrying its own newlines must count as the rows
        # it actually occupies, or the next frame''s cursor-up math desyncs (#356).
        $f = & $script:mod { Get-LivePaneFrame -Lines @("a`nb`nc") -PreviousLineCount 0 }
        $f.Text | Should -Be "a`nb`nc"
        $f.LineCount | Should -Be 3
    }

    It 'truncates each drawn row to Width so it cannot wrap' {
        $f = & $script:mod { Get-LivePaneFrame -Lines @('abcdefghij') -PreviousLineCount 0 -Width 4 }
        $f.Text | Should -Be 'abcd'
        $f.LineCount | Should -Be 1
    }
}

Describe 'Get-LivePaneClear' -Tag 'Light','Module' {
    It 'returns an empty string when nothing was drawn' {
        (& $script:mod { Get-LivePaneClear -PreviousLineCount 0 }) | Should -Be ''
    }

    It 'moves to the top of the block and clears to the end of the display' {
        $c = & $script:mod { Get-LivePaneClear -PreviousLineCount 4 }
        $c | Should -Be "$($script:ESC)[3F$($script:ESC)[0J"
    }
}

Describe 'Sticky scroll-region helpers' -Tag 'Light','Module' {
    It 'Get-StickyRegionEnter sets the scroll region above the bar and parks the cursor' {
        # Height 30, 1 bar row => scroll region rows 1..29, cursor parked at 29;1.
        $s = & $script:mod { Get-StickyRegionEnter -Height 30 -BarRows 1 }
        $s | Should -Be "$($script:ESC)[1;29r$($script:ESC)[29;1H"
    }

    It 'Get-StickyRegionEnter accounts for a taller bar' {
        $s = & $script:mod { Get-StickyRegionEnter -Height 30 -BarRows 2 }
        $s | Should -Be "$($script:ESC)[1;28r$($script:ESC)[28;1H"
    }

    It 'Get-StickyStatusFrame saves the cursor, paints the bar row, and restores' {
        # Bar row for Height 30 / 1 bar row is row 30.
        $s = & $script:mod { Get-StickyStatusFrame -Status 'Updating X' -Height 30 -BarRows 1 -Width 80 }
        # ESC7 save, move to 30;1, clear line, inverse status, reset, ESC8 restore.
        $expected = "$($script:ESC)7$($script:ESC)[30;1H$($script:ESC)[2K$($script:ESC)[7mUpdating X$($script:ESC)[0m$($script:ESC)8"
        $s | Should -Be $expected
    }

    It 'Get-StickyStatusFrame clips the status to Width so the bar never wraps' {
        $s = & $script:mod { Get-StickyStatusFrame -Status 'abcdefghij' -Height 10 -BarRows 1 -Width 4 }
        $s | Should -Match ([regex]::Escape("$($script:ESC)[7mabcd$($script:ESC)[0m"))
        $s | Should -Not -Match 'efghij'
    }

    It 'Get-StickyLogLine writes the first line in place and later lines after a newline' {
        $first = & $script:mod { Get-StickyLogLine -Text 'first' -Width 80 -IsFirst $true }
        $first | Should -Be 'first'
        $next = & $script:mod { Get-StickyLogLine -Text 'second' -Width 80 -IsFirst $false }
        $next | Should -Be "`nsecond"
    }

    It 'Get-StickyLogLine splits an embedded-newline record into separate scrolled rows' {
        $s = & $script:mod { Get-StickyLogLine -Text "a`nb" -Width 80 -IsFirst $false }
        $s | Should -Be "`na`nb"
    }

    It 'Get-StickyLogLine clips each row to Width' {
        $s = & $script:mod { Get-StickyLogLine -Text 'abcdefghij' -Width 4 -IsFirst $true }
        $s | Should -Be 'abcd'
    }

    It 'Get-StickyRegionLeave resets the region and clears the bar, leaving the log above' {
        # Height 30 / 1 bar row: reset region, move to first bar row (30), clear to end.
        $s = & $script:mod { Get-StickyRegionLeave -Height 30 -BarRows 1 }
        $s | Should -Be "$($script:ESC)[r$($script:ESC)[30;1H$($script:ESC)[0J"
    }
}

Describe 'Write-LivePane' -Tag 'Light','Module' {
    It 'mirrors the status to the verbose stream even when the visual mode is Off' {
        $v = & $script:mod {
            $VerbosePreference = 'Continue'
            Write-LivePane -Status 'hello-pane' -Mode 'Off'
        } 4>&1
        @($v | Where-Object { "$_" -match 'hello-pane' }) | Should -Not -BeNullOrEmpty
    }

    It 'tracks the drawn line count across Multiline calls and resets on completion' {
        $counts = & $script:mod {
            $script:LivePaneLineCount = 0
            $script:LivePaneBuffer = $null
            Write-LivePane -Status 'one' -Mode 'Multiline'
            Write-LivePane -Status 'two' -Mode 'Multiline'
            $after = $script:LivePaneLineCount
            Write-LivePane -Completed -Mode 'Multiline'
            [pscustomobject]@{ After = $after; Reset = $script:LivePaneLineCount }
        } 6>$null
        $counts.After | Should -Be 2
        $counts.Reset | Should -Be 0
    }

    It 'activates the sticky region on the first Sticky write and tears it down on completion' {
        $state = & $script:mod {
            $script:StickyActive = $false
            $script:StickyStarted = $false
            Write-LivePane -Status 'one' -Mode 'Sticky'
            $activeAfterFirst = $script:StickyActive
            $startedAfterFirst = $script:StickyStarted
            Write-LivePane -Status 'two' -Mode 'Sticky'
            Write-LivePane -Completed -Mode 'Sticky'
            [pscustomobject]@{
                ActiveAfterFirst  = $activeAfterFirst
                StartedAfterFirst = $startedAfterFirst
                ActiveAfterDone   = $script:StickyActive
            }
        } 6>$null
        $state.ActiveAfterFirst  | Should -BeTrue
        $state.StartedAfterFirst | Should -BeTrue
        $state.ActiveAfterDone   | Should -BeFalse
    }

    It 'mirrors Sticky status lines to the verbose stream (recoverable transcript)' {
        $v = & $script:mod {
            $script:StickyActive = $false
            $script:StickyStarted = $false
            $VerbosePreference = 'Continue'
            Write-LivePane -Status 'sticky-verbose-line' -Mode 'Sticky'
            Write-LivePane -Completed -Mode 'Sticky'
        } 4>&1 6>$null
        @($v | Where-Object { "$_" -match 'sticky-verbose-line' }) | Should -Not -BeNullOrEmpty
    }

    It 'tears down an active sticky region on completion even when Mode now resolves to Single' {
        # Guards against a mid-run host-fact shift leaving the VT scroll region leaked:
        # teardown is driven by the active-region flag, not the freshly-resolved Mode.
        $active = & $script:mod {
            $script:StickyActive = $false
            $script:StickyStarted = $false
            Write-LivePane -Status 'one' -Mode 'Sticky'
            $afterFirst = $script:StickyActive
            Write-LivePane -Completed -Mode 'Single'
            [pscustomobject]@{ AfterFirst = $afterFirst; AfterDone = $script:StickyActive }
        } 6>$null
        $active.AfterFirst | Should -BeTrue
        $active.AfterDone  | Should -BeFalse
    }
}
