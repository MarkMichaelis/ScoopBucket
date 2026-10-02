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
    # Cleared too: a run from inside a Claude tab would otherwise leak its own tab token.
    $script:savedEnv = @{ WT_SESSION = $env:WT_SESSION; CLAUDECODE = $env:CLAUDECODE; CLAUDE_TAB_TOKEN = $env:CLAUDE_TAB_TOKEN }
    $env:CLAUDE_TAB_TOKEN = $null
    $env:WT_SESSION = $null
    $env:CLAUDECODE = $null
    Remove-Variable -Name ClaudeTabOriginalPrompt, ClaudeTabPendingRestore -Scope Global -ErrorAction Ignore
    Set-Item function:global:prompt -Value { 'ORIGINAL> ' }
    Import-Module $script:psm1 -Force
    $script:tabs = Get-Module MarkMichaelisClaudeTabs

    $script:state = Join-Path $TestDrive 'state'
    New-Item -ItemType Directory -Path (Join-Path $script:state 'sessions') -Force | Out-Null
    function Get-LongPath([string]$Path) {
        Push-Location -LiteralPath $Path
        try { (Get-Location).ProviderPath } finally { Pop-Location }
    }

    # The roaming root map, the home folder, and the temp folder all live in TestDrive.
    $script:store = Join-Path $script:state 'od\Documents\WindowsTerminalTabs'
    $script:homeDir = Join-Path $TestDrive 'home'
    New-Item -ItemType Directory -Path (Join-Path $script:homeDir 'Documents\notes'), (Join-Path $TestDrive 'tmp\scratch') -Force | Out-Null
    $script:homeDir = Get-LongPath $script:homeDir
    & $script:tabs {
        param($root, $store, $homeDir, $temp)
        $script:TabsRoot = $root
        $script:SessionsRoot = Join-Path $root 'sessions'
        $script:StoreDir = $store
        $script:RootsFile = Join-Path $store 'tab-roots.json'
        $script:LegacyRoamingColors = Join-Path $store 'colors.json'
        $script:LegacyLocalColors = Join-Path $root 'colors.json'
        $script:HomeDir = $homeDir
        $script:TempDir = $temp
    } $script:state $script:store $script:homeDir (Join-Path $TestDrive 'tmp')

    # A main repository with a linked worktree, like this bucket's .worktrees layout.
    $script:repo = Join-Path $TestDrive 'repo'
    git init -q $script:repo
    git -C $script:repo -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
    git -C $script:repo remote add origin 'git@github.com:Contoso/Widget.git'
    New-Item -ItemType Directory -Path (Join-Path $script:repo 'src') | Out-Null
    $script:worktree = Join-Path $TestDrive 'repo-wt'
    git -C $script:repo worktree add -q $script:worktree -b wt 2>$null
    $script:repo = Get-LongPath $script:repo
    $script:worktree = Get-LongPath $script:worktree
    # A repository under home, with an origin that is not on GitHub.
    $script:inner = Join-Path $script:homeDir 'code\Inner'
    git init -q $script:inner
    git -C $script:inner remote add origin 'https://dev.azure.com/contoso/proj/_git/inner'
    $script:plain = Join-Path $TestDrive 'plain'
    New-Item -ItemType Directory -Path (Join-Path $script:plain 'sub') -Force | Out-Null
    $script:plain = Get-LongPath $script:plain

    function Get-Root([string]$Path) { Get-ClaudeTabRoot -Path $Path }
    function Reset-TabColors {
        Remove-Item -LiteralPath $script:store -Recurse -Force -ErrorAction Ignore
        Remove-Item -LiteralPath (Join-Path $script:state 'colors.json*') -Force -ErrorAction Ignore
        & $script:tabs { $script:Store = $null; $script:StoreStamp = $null; $script:GitCache = @{} }
    }

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
    $env:CLAUDE_TAB_TOKEN = $script:savedEnv.CLAUDE_TAB_TOKEN
    git -C $script:repo worktree remove --force $script:worktree 2>$null
    # git marks object files read-only, which TestDrive cleanup cannot delete.
    Remove-Item -LiteralPath $script:repo, $script:worktree, $script:inner -Recurse -Force -ErrorAction Ignore
}

Describe 'Claude tabs: colors by root' -Tag 'Light', 'Bucket' {
    BeforeEach { Reset-TabColors }

    It 'colors a repository, its subfolders, and its linked worktrees as one root keyed by its GitHub identity' {
        $roots = foreach ($dir in $script:repo, (Join-Path $script:repo 'src'), $script:worktree) { Get-Root $dir }

        $roots.Kind | Should -Be @('Repository', 'Repository', 'Repository')
        $roots.Key | Should -Be @('contoso/widget', 'contoso/widget', 'contoso/widget')
        @($roots.Color | Select-Object -Unique).Count | Should -Be 1
        $roots[0].Color | Should -Match '^#[0-9A-F]{6}$'
    }

    It 'keys a repository by its GitHub owner/repo whatever the origin form, else by its folder name' -TestCases @(
        @{ Url = 'git@github.com:Owner/Repo.git'; Key = 'owner/repo' }
        @{ Url = 'ssh://git@github.com/Owner/Repo'; Key = 'owner/repo' }
        @{ Url = 'https://github.com/Owner/Repo/'; Key = 'owner/repo' }
        @{ Url = 'https://token@github.com/Owner/Repo.git/'; Key = 'owner/repo' }
        @{ Url = 'https://dev.azure.com/o/p/_git/repo'; Key = 'clone' }
        @{ Url = ''; Key = 'clone' }
    ) {
        param($Url, $Key)
        & $script:tabs { param($u) ConvertTo-ClaudeTabRepoKey -Url $u -Folder 'D:\Git\Clone' } $Url | Should -Be $Key
    }

    It 'colors the home folder and its subfolders as one root, while a repository under home keeps its own' {
        $homeRoot = Get-Root $script:homeDir
        $notes = Get-Root (Join-Path $script:homeDir 'Documents\notes')
        $inner = Get-Root $script:inner

        $homeRoot.Kind, $homeRoot.Key | Should -Be @('Home', '~')
        $notes.Key | Should -Be '~'
        $notes.Color | Should -Be $homeRoot.Color
        $inner.Kind, $inner.Key | Should -Be @('Repository', 'inner')
        $inner.Color | Should -Not -Be $homeRoot.Color
    }

    It 'leaves folders under no root with the default color' {
        $root = Get-Root $script:plain

        $root.Kind | Should -Be 'None'
        $root.Color | Should -BeNullOrEmpty
    }

    It 'marks a folder as a root of its own, keyed relative to home when under it' {
        $plain = Set-ClaudeTabRoot -Path $script:plain
        $documents = Set-ClaudeTabRoot -Path (Join-Path $script:homeDir 'Documents')

        $sub = Get-Root (Join-Path $script:plain 'sub')
        $sub.Kind, $sub.Key, $sub.Color | Should -Be @('Marked', $script:plain.ToLowerInvariant(), $plain.Color)
        $notes = Get-Root (Join-Path $script:homeDir 'Documents\notes')
        $notes.Key, $notes.Color | Should -Be @('~\documents', $documents.Color)
        (Get-Root $script:homeDir).Key | Should -Be '~'
        @($plain.Color, $documents.Color, (Get-Root $script:homeDir).Color, (Get-Root $script:repo).Color | Select-Object -Unique).Count | Should -Be 4
    }

    It 'uses a color given when marking, and only recolors a folder that already is a root' {
        Set-ClaudeTabRoot -Path $script:plain -Color '#abcdef' | Out-Null
        Set-ClaudeTabRoot -Path $script:repo -Color '#123456' | Out-Null
        Set-ClaudeTabRoot -Path $script:plain -Color '#654321' | Out-Null

        (Get-Root (Join-Path $script:plain 'sub')).Color | Should -Be '#654321'
        (Get-Root $script:worktree).Color | Should -Be '#123456'
        $saved = Get-Content -LiteralPath (Join-Path $script:store 'tab-roots.json') -Raw | ConvertFrom-Json -AsHashtable
        @($saved['roots']) | Should -Be @($script:plain.ToLowerInvariant())
    }

    It 'unmarks a root, so its folders go back to their parent root' {
        Set-ClaudeTabRoot -Path (Join-Path $script:homeDir 'Documents') | Out-Null

        Remove-ClaudeTabRoot -Path (Join-Path $script:homeDir 'Documents')

        (Get-Root (Join-Path $script:homeDir 'Documents\notes')).Kind | Should -Be 'Home'
        Remove-ClaudeTabRoot -Path $script:repo -WarningVariable warned -WarningAction SilentlyContinue
        $warned | Should -Not -BeNullOrEmpty
    }

    It 'hands out the palette first, then colors that do not repeat, skipping colors already taken' {
        $sequence = & $script:tabs { 0..299 | ForEach-Object { Get-ClaudeTabSequenceColor $_ } }

        $sequence[0..11] | Should -Be @('#2E86DE', '#E67E22', '#27AE60', '#C0392B', '#8E44AD', '#16A085', '#D81B60', '#B7950B', '#3949AB', '#6D4C41', '#00838F', '#7CB342')
        @($sequence | Select-Object -Unique).Count | Should -Be 300
        & $script:tabs { Get-ClaudeTabNextColor ([ordered]@{ a = '#2e86de'; b = '#27AE60' }) } | Should -Be '#E67E22'
    }

    It 'keeps a root''s color across sessions in a roaming map' {
        $first = (Get-Root $script:repo).Color
        & $script:tabs { $script:Store = $null; $script:GitCache = @{} }

        (Get-Root $script:worktree).Color | Should -Be $first
        $saved = Get-Content -LiteralPath (Join-Path $script:store 'tab-roots.json') -Raw | ConvertFrom-Json -AsHashtable
        $saved['version'] | Should -Be 2
        $saved['colors']['contoso/widget'] | Should -Be $first
    }

    It 'calls git once per new folder' {
        Mock git -ModuleName MarkMichaelisClaudeTabs { & (Get-Command git -CommandType Application | Select-Object -First 1) @args }

        1..3 | ForEach-Object { Get-Root (Join-Path $script:repo 'src') } | Out-Null

        Should -Invoke git -ModuleName MarkMichaelisClaudeTabs -Times 1 -Exactly
    }

    It 'migrates path-keyed maps to identity keys, keeping colors and dropping missing and temp folders' {
        New-Item -ItemType Directory -Path $script:store -Force | Out-Null
        $roaming = [ordered]@{
            $script:repo.ToLowerInvariant()                         = '#C0392B'
            $script:homeDir.ToLowerInvariant()                         = '#8E44AD'
            $script:plain.ToLowerInvariant()                        = '#16A085'
            'c:\no\such\folder446'                                  = '#B7950B'
            (Join-Path $TestDrive 'tmp\scratch').ToLowerInvariant() = '#3949AB'
        }
        $roaming | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:store 'colors.json')
        $local = [ordered]@{ $script:worktree.ToLowerInvariant() = '#D81B60'; $script:inner.ToLowerInvariant() = '#00838F' }
        $local | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:state 'colors.json')

        (Get-Root $script:repo).Color | Should -Be '#C0392B'

        $saved = Get-Content -LiteralPath (Join-Path $script:store 'tab-roots.json') -Raw | ConvertFrom-Json -AsHashtable
        $saved['colors'].Keys | Sort-Object | Should -Be (@('~', 'contoso/widget', 'inner', $script:plain.ToLowerInvariant()) | Sort-Object)
        $saved['colors']['~'] | Should -Be '#8E44AD'
        $saved['colors']['inner'] | Should -Be '#00838F'
        @($saved['roots']) | Should -Be @($script:plain.ToLowerInvariant())
        Join-Path $script:state 'colors.json' | Should -Not -Exist
        Join-Path $script:state 'colors.json.migrated' | Should -Exist
        Join-Path $script:store 'colors.json' | Should -Exist
    }

    It 'never overwrites a map it cannot read, and ignores OneDrive conflict copies' {
        New-Item -ItemType Directory -Path $script:store -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:store 'tab-roots.json') -Value 'not json {'
        '{ "version": 2, "colors": { "contoso/widget": "#ABCDEF" }, "roots": [] }' |
            Set-Content -LiteralPath (Join-Path $script:store 'tab-roots-OTHERPC.json')

        $color = (Get-Root $script:repo).Color

        $color | Should -Be '#2E86DE'
        (Get-Content -LiteralPath (Join-Path $script:store 'tab-roots.json') -Raw).Trim() | Should -Be 'not json {'
        { Set-ClaudeTabRoot -Path $script:plain } | Should -Throw '*not valid JSON*'
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

Describe 'Claude tabs: Git Bash tabs get the same root and color' -Tag 'Light', 'Bucket' -Skip:(-not $hasNode) {
    BeforeAll {
        # The helper finds the roaming map and home folder the way the module does.
        $script:savedParityEnv = @{ USERPROFILE = $env:USERPROFILE; OneDriveCommercial = $env:OneDriveCommercial }
        $env:USERPROFILE = $script:homeDir
        $env:OneDriveCommercial = Join-Path $script:state 'od'
        function Get-BashColor([string]$Path) { node $script:helper color $Path }
    }
    AfterAll {
        $env:USERPROFILE = $script:savedParityEnv.USERPROFILE
        $env:OneDriveCommercial = $script:savedParityEnv.OneDriveCommercial
    }
    BeforeEach { Reset-TabColors }

    It 'computes the same color sequence' {
        $node = @(node $script:helper sequence 120)
        $ps = & $script:tabs { 0..119 | ForEach-Object { Get-ClaudeTabSequenceColor $_ } }

        $node | Should -Be $ps
    }

    It 'resolves repositories, home, marked roots, and unrooted folders as PowerShell does' {
        $bashRepo = Get-BashColor (Join-Path $script:repo 'src')
        $bashHome = Get-BashColor (Join-Path $script:homeDir 'Documents\notes')
        $marked = Set-ClaudeTabRoot -Path $script:plain

        $bashRepo | Should -Match '^#[0-9A-F]{6}$'
        (Get-Root $script:worktree).Color | Should -Be $bashRepo
        (Get-Root $script:homeDir).Color | Should -Be $bashHome
        Get-BashColor (Join-Path $script:plain 'sub') | Should -Be $marked.Color
        Get-BashColor $script:inner | Should -Be (Get-Root $script:inner).Color
        Get-BashColor (Join-Path $TestDrive 'tmp') | Should -BeNullOrEmpty
    }

    It 'leaves a path-keyed map from an earlier version for PowerShell to migrate' {
        New-Item -ItemType Directory -Path $script:store -Force | Out-Null
        '{ "c:\\git\\x": "#2E86DE" }' | Set-Content -LiteralPath (Join-Path $script:store 'colors.json')

        Get-BashColor $script:repo | Should -BeNullOrEmpty
        Join-Path $script:store 'tab-roots.json' | Should -Not -Exist
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
