#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior coverage for the Windows Terminal tab integration installed by the
    Windows Terminal ConfigScript (#412): MarkMichaelisClaudeTabs.psm1 (PowerShell),
    its Node.js helper (the Git Bash side), and the Claude Code tab-session hook.

.DESCRIPTION
    Everything runs in TestDrive: temporary git repositories stand in for real
    projects, a fake claude executable records how it was launched, and the tab
    module's state folders are redirected. The module is imported with WT_SESSION
    cleared, so importing it has no side effects; tests set WT_SESSION only where the
    behavior under test needs Windows Terminal. The global prompt and environment are
    restored afterward.
#>

BeforeDiscovery {
    $hasNode = [bool](Get-Command node -ErrorAction Ignore)
}

BeforeAll {
    $script:psm1 = Join-Path $PSScriptRoot 'MarkMichaelisClaudeTabs.psm1'
    $script:helper = Join-Path $PSScriptRoot 'MarkMichaelisClaudeTabs.js'
    $script:hook = Join-Path $PSScriptRoot '..\ai\MarkMichaelisClaudeTabSessionHook.js'

    $script:savedPrompt = (Get-Command -Name prompt -CommandType Function -ErrorAction Ignore).ScriptBlock
    $script:savedEnv = @{ WT_SESSION = $env:WT_SESSION; CLAUDECODE = $env:CLAUDECODE }
    $env:WT_SESSION = $null
    $env:CLAUDECODE = $null
    Remove-Variable -Name ClaudeTabOriginalPrompt, ClaudeTabPendingRestore -Scope Global -ErrorAction Ignore
    Set-Item function:global:prompt -Value { 'ORIGINAL> ' }
    Import-Module $script:psm1 -Force
    $script:tabs = Get-Module MarkMichaelisClaudeTabs

    $script:state = Join-Path $TestDrive 'state'
    New-Item -ItemType Directory -Path (Join-Path $script:state 'sessions') -Force | Out-Null
    & $script:tabs {
        param($root)
        $script:TabsRoot = $root
        $script:SessionsRoot = Join-Path $root 'sessions'
        $script:ColorsFile = Join-Path $root 'colors.json'
    } $script:state

    function Get-LongPath([string]$Path) {
        Push-Location -LiteralPath $Path
        try { (Get-Location).ProviderPath } finally { Pop-Location }
    }

    # A main repository with a linked worktree, like this bucket's .worktrees layout.
    $script:repo = Join-Path $TestDrive 'repo'
    git init -q $script:repo
    git -C $script:repo -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
    New-Item -ItemType Directory -Path (Join-Path $script:repo 'src') | Out-Null
    $script:worktree = Join-Path $TestDrive 'repo-wt'
    git -C $script:repo worktree add -q $script:worktree -b wt 2>$null
    $script:plain = Join-Path $TestDrive 'plain'
    New-Item -ItemType Directory -Path $script:plain | Out-Null

    # Fake claude: records its arguments, its tab token, and whether the record existed.
    $script:fakeOut = Join-Path $TestDrive 'fake-out.txt'
    $script:fake = Join-Path $TestDrive 'fake-claude.cmd'
    Set-Content -LiteralPath $script:fake -Encoding ascii -Value @(
        '@echo off'
        "echo ARGS:%*>>`"$script:fakeOut`""
        "echo TOKEN:%CLAUDE_TAB_TOKEN%>>`"$script:fakeOut`""
        "if exist `"$script:state\sessions\%CLAUDE_TAB_TOKEN%\record.json`" echo RECORD:yes>>`"$script:fakeOut`""
    )
    & $script:tabs { param($f) $script:ClaudeExe = $f } $script:fake

    function Invoke-FakeClaude {
        Remove-Item -LiteralPath $script:fakeOut -ErrorAction Ignore
        claude @args | Out-Null
        Get-Content -LiteralPath $script:fakeOut -Raw
    }

    function New-TabRecord {
        param([string]$Token, [int]$ShellPid, [string]$ShellStart, $Ended)
        $dir = Join-Path $script:state "sessions\$Token"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $record = [ordered]@{
            token = $Token; launchDir = $script:repo; keepArgs = @('--permission-mode', 'auto')
            sessionId = 'sess-abc'; shellPid = $ShellPid; shellStart = $ShellStart
        }
        if ($Ended) { $record.ended = $Ended }
        $record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'record.json')
        $dir
    }
}

AfterAll {
    Remove-Module MarkMichaelisClaudeTabs -Force -ErrorAction Ignore
    if ($script:savedPrompt) { Set-Item function:global:prompt -Value $script:savedPrompt }
    Remove-Variable -Name ClaudeTabOriginalPrompt, ClaudeTabPendingRestore -Scope Global -ErrorAction Ignore
    $env:WT_SESSION = $script:savedEnv.WT_SESSION
    $env:CLAUDECODE = $script:savedEnv.CLAUDECODE
    git -C $script:repo worktree remove --force $script:worktree 2>$null
    # git marks object files read-only, which TestDrive cleanup cannot delete.
    Remove-Item -LiteralPath $script:repo, $script:worktree -Recurse -Force -ErrorAction Ignore
}

Describe 'Claude tabs: colors by repository' -Tag 'Light', 'Bucket' {
    BeforeEach {
        Remove-Item -LiteralPath (Join-Path $script:state 'colors.json') -ErrorAction Ignore
        & $script:tabs { $script:ColorMap = $null; $script:RootCache = @{} }
    }

    It 'gives a repository, its subfolders, and its linked worktrees the same root' {
        $expected = Get-LongPath $script:repo
        foreach ($dir in $script:repo, (Join-Path $script:repo 'src'), $script:worktree) {
            $root = & $script:tabs { param($d) Get-ClaudeTabProjectRoot $d } $dir
            Get-LongPath $root | Should -Be $expected -Because "$dir belongs to the repository"
        }
    }

    It 'leaves folders outside any repository uncolored' {
        & $script:tabs { param($d) Get-ClaudeTabProjectRoot $d } $script:plain | Should -BeNullOrEmpty
    }

    It 'treats the first folder under C:\Git as the project when it is not a repository' {
        & $script:tabs { Get-ClaudeTabProjectRoot 'C:\Git\NoSuchRepo412\sub' } | Should -Be 'C:\Git\NoSuchRepo412'
    }

    It 'keeps committed colors and gives a new repository an unused, stable color' {
        '{ "c:\\git\\one": "#2E86DE", "c:\\git\\two": "#E67E22" }' | Set-Content -LiteralPath (Join-Path $script:state 'colors.json')

        $new = & $script:tabs { Get-ClaudeTabColor 'C:\Git\Three' }
        & $script:tabs { $script:ColorMap = $null }
        $again = & $script:tabs { Get-ClaudeTabColor 'c:\git\three' }

        (& $script:tabs { Get-ClaudeTabColor 'C:\Git\One' }) | Should -Be '#2E86DE'
        $new | Should -Not -BeIn @('#2E86DE', '#E67E22')
        $again | Should -Be $new
    }
}

Describe 'Claude tabs: the claude wrapper' -Tag 'Light', 'Bucket' {
    BeforeEach {
        $env:WT_SESSION = 'test'
        Set-Location -LiteralPath $script:repo
    }
    AfterEach {
        $env:WT_SESSION = $null
        $env:CLAUDECODE = $null
        Set-Location -LiteralPath $TestDrive
    }

    It 'passes arguments through with a tab token and a live record, then cleans up' {
        # Splatted: PowerShell drops a literally typed `--` before any function sees it.
        $launch = @('--name', 'x', '--permission-mode', 'auto', '--', 'hello world')
        $out = Invoke-FakeClaude @launch

        $out | Should -Match 'ARGS:--name x --permission-mode auto -- "hello world"'
        $out | Should -Match 'TOKEN:[0-9a-f]{32}'
        $out | Should -Match 'RECORD:yes'
        @(Get-ChildItem -LiteralPath (Join-Path $script:state 'sessions') -Directory).Count | Should -Be 0
        $env:CLAUDE_TAB_TOKEN | Should -BeNullOrEmpty
    }

    It 'passes straight through when run by Claude itself' {
        $env:CLAUDECODE = '1'

        $out = Invoke-FakeClaude --version

        $out | Should -Match 'ARGS:--version'
        $out | Should -Not -Match 'TOKEN:[0-9a-f]{32}'
    }

    It 'keeps only the launch options worth resuming with' {
        $keep = & $script:tabs { Get-ClaudeResumeArgs @('--name', 'x', '--remote-control', '--permission-mode', 'auto', '--model', 'opus', '--', '-do this') }

        $keep -join ' ' | Should -Be '--remote-control --permission-mode auto --model opus'
    }
}

Describe 'Claude tabs: restoring a tab after a restart' -Tag 'Light', 'Bucket' {
    BeforeEach {
        $env:WT_SESSION = 'test'
        $global:ClaudeTabPendingRestore = $null
    }
    AfterEach {
        $env:WT_SESSION = $null
        $global:ClaudeTabPendingRestore = $null
        Set-Location -LiteralPath $TestDrive
    }

    It 'resumes the recorded session with its options instead of re-running the launch command' {
        Set-Location -LiteralPath (New-TabRecord -Token ('a' * 32) -ShellPid 999999 -ShellStart '1')
        & $script:tabs { Initialize-ClaudeTabRestore }

        Get-LongPath (Get-Location).Path | Should -Be (Get-LongPath $script:repo)
        $global:ClaudeTabPendingRestore.sessionId | Should -Be 'sess-abc'

        $out = Invoke-FakeClaude --name original -- 'original prompt'

        $out | Should -Match 'ARGS:--resume sess-abc --permission-mode auto\s*\r?\n'
        $global:ClaudeTabPendingRestore | Should -BeNullOrEmpty
    }

    It 'does not resume from a duplicate of a tab whose Claude is still running' {
        $me = (Get-Process -Id $PID).StartTime.ToFileTimeUtc().ToString()
        Set-Location -LiteralPath (New-TabRecord -Token ('b' * 32) -ShellPid $PID -ShellStart $me)

        & $script:tabs { Initialize-ClaudeTabRestore }

        $global:ClaudeTabPendingRestore | Should -BeNullOrEmpty
        Get-LongPath (Get-Location).Path | Should -Be (Get-LongPath $script:repo)
    }

    It 'does not resume a session the user had already exited' {
        Set-Location -LiteralPath (New-TabRecord -Token ('c' * 32) -ShellPid 999999 -ShellStart '1' -Ended @{ sessionId = 'sess-abc'; reason = 'prompt_input_exit' })

        & $script:tabs { Initialize-ClaudeTabRestore }

        $global:ClaudeTabPendingRestore | Should -BeNullOrEmpty
    }

    It 'still resumes when Claude reported "other" while being shut down' {
        Set-Location -LiteralPath (New-TabRecord -Token ('d' * 32) -ShellPid 999999 -ShellStart '1' -Ended @{ sessionId = 'sess-abc'; reason = 'other' })

        & $script:tabs { Initialize-ClaudeTabRestore }

        $global:ClaudeTabPendingRestore.sessionId | Should -Be 'sess-abc'
    }

    It 'sends a tab whose record is gone to the home folder' {
        $orphan = Join-Path $script:state ('sessions\' + ('e' * 32))
        New-Item -ItemType Directory -Path $orphan -Force | Out-Null
        Set-Location -LiteralPath $orphan

        & $script:tabs { Initialize-ClaudeTabRestore }

        (Get-Location).Path | Should -Be $HOME
    }
}

Describe 'Claude tabs: prompt' -Tag 'Light', 'Bucket' {
    It 'still renders the original prompt and preserves the last exit code' {
        $global:LASTEXITCODE = 7

        prompt | Should -Be 'ORIGINAL> '
        $global:LASTEXITCODE | Should -Be 7
    }
}

Describe 'Claude tabs: Git Bash helper and tab-session hook' -Tag 'Light', 'Bucket' -Skip:(-not $hasNode) {
    BeforeAll {
        $script:nodeHome = Join-Path $TestDrive 'node-home'
        New-Item -ItemType Directory -Path $script:nodeHome | Out-Null
        $script:savedNodeEnv = @{ USERPROFILE = $env:USERPROFILE; CLAUDE_TAB_TOKEN = $env:CLAUDE_TAB_TOKEN; CLAUDE_PID = $env:CLAUDE_PID }
        $env:USERPROFILE = $script:nodeHome
        $script:token = 'f' * 32
        $script:tokenDir = Join-Path $script:nodeHome ".claude\terminal-tabs\sessions\$script:token"

        function Invoke-Hook([string]$Json, [int]$ClaudePid) {
            $env:CLAUDE_TAB_TOKEN = $script:token
            $env:CLAUDE_PID = $ClaudePid
            try { $Json | node $script:hook } finally { $env:CLAUDE_TAB_TOKEN = $null; $env:CLAUDE_PID = $null }
        }
        function Read-Record { Get-Content -LiteralPath (Join-Path $script:tokenDir 'record.json') -Raw | ConvertFrom-Json }
    }
    AfterAll {
        $env:USERPROFILE = $script:savedNodeEnv.USERPROFILE
        $env:CLAUDE_TAB_TOKEN = $script:savedNodeEnv.CLAUDE_TAB_TOKEN
        $env:CLAUDE_PID = $script:savedNodeEnv.CLAUDE_PID
    }

    It 'gives Git Bash tabs the same colors PowerShell tabs read' {
        $bashColor = node $script:helper color (Join-Path $script:repo 'src')
        & $script:tabs { param($f) $script:ColorsFile = $f; $script:ColorMap = $null; $script:RootCache = @{} } (Join-Path $script:nodeHome '.claude\terminal-tabs\colors.json')
        try {
            $psColor = & $script:tabs { param($d) Get-ClaudeTabColor (Get-ClaudeTabProjectRoot $d) } $script:worktree
        }
        finally {
            & $script:tabs { param($f) $script:ColorsFile = $f; $script:ColorMap = $null } (Join-Path $script:state 'colors.json')
        }

        $bashColor | Should -Match '^#[0-9A-F]{6}$'
        $psColor | Should -Be $bashColor
        node $script:helper color $script:plain | Should -BeNullOrEmpty
    }

    It 'records a session through the hook and keeps the shell start time exact' {
        node $script:helper record $script:token $script:repo 999999 '134334570206400672' '' -- --permission-mode auto --name x

        Invoke-Hook '{"hook_event_name":"SessionStart","session_id":"s1","cwd":"C:/x","source":"startup"}' 111

        $record = Read-Record
        $record.sessionId | Should -Be 's1'
        $record.claudePid | Should -Be 111
        $record.keepArgs -join ' ' | Should -Be '--permission-mode auto'
        (Get-Content -LiteralPath (Join-Path $script:tokenDir 'record.json') -Raw) | Should -Match '"shellStart": "134334570206400672"'
    }

    It 'ignores a claude started from inside the session, then follows /clear' {
        Invoke-Hook '{"hook_event_name":"SessionStart","session_id":"nested","cwd":"C:/x","source":"startup"}' 222
        (Read-Record).sessionId | Should -Be 's1'

        Invoke-Hook '{"hook_event_name":"SessionEnd","session_id":"s1","reason":"clear"}' 111
        Invoke-Hook '{"hook_event_name":"SessionStart","session_id":"s2","cwd":"C:/x","source":"clear"}' 111

        $record = Read-Record
        $record.sessionId | Should -Be 's2'
        $record.PSObject.Properties.Name | Should -Not -Contain 'ended'
    }

    It 'ignores session events from a subagent, which shares the tab''s claude process' {
        Invoke-Hook '{"hook_event_name":"SessionStart","session_id":"sub","cwd":"C:/x","source":"startup","agent_id":"a1"}' 111

        (Read-Record).sessionId | Should -Be 's2'
    }

    It 'tells a restored Git Bash tab which session to resume' {
        $lines = @(node $script:helper restore $script:tokenDir)

        $lines[0] | Should -Be $script:repo
        $lines[1] | Should -Be 's2'
        $lines[2] | Should -Be $script:token
        $lines[3..($lines.Count - 1)] -join ' ' | Should -Be '--permission-mode auto'
    }
}
