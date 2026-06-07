<#
.SYNOPSIS
    Light-suite Pester coverage for the host-adaptive live-output pane helpers
    (#354).

.DESCRIPTION
    The multiline pane is the portability risk, so its decision logic and frame
    strings are pure and pinned here:

      * Resolve-LiveOutputMode resolves Multiline only for a genuinely interactive,
        VT-capable, non-VS-Code, non-CI, non-redirected, non-ISE console; every
        other signature is Single, and a silenced progress preference is Off.
      * Get-LivePaneFrame / Get-LivePaneClear emit the exact cursor-move + clear
        sequences and account for the drawn line count.
      * Write-LivePane mirrors to verbose in every mode and maintains the pane's
        line-count state across calls / teardown.
#>

BeforeAll {
    $script:moduleManifest = Resolve-Path (Join-Path $PSScriptRoot '..\MarkMichaelis.ScoopBucket.psd1')
    Import-Module $script:moduleManifest -Force
    $script:mod = Get-Module MarkMichaelis.ScoopBucket
    $script:ESC = [char]27
}

Describe 'Resolve-LiveOutputMode' {
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

    It 'returns Multiline only for a capable interactive console' {
        $m = & $script:mod {
            Resolve-LiveOutputMode -TermProgram 'WindowsTerminal' -Ci '' -OutputRedirected $false `
                -HostName 'ConsoleHost' -SupportsVirtualTerminal $true -ProgressPreferenceValue 'Continue'
        }
        $m | Should -Be 'Multiline'
    }
}

Describe 'Get-LivePaneFrame' {
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
}

Describe 'Get-LivePaneClear' {
    It 'returns an empty string when nothing was drawn' {
        (& $script:mod { Get-LivePaneClear -PreviousLineCount 0 }) | Should -Be ''
    }

    It 'moves to the top of the block and clears to the end of the display' {
        $c = & $script:mod { Get-LivePaneClear -PreviousLineCount 4 }
        $c | Should -Be "$($script:ESC)[3F$($script:ESC)[0J"
    }
}

Describe 'Write-LivePane' {
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
}
