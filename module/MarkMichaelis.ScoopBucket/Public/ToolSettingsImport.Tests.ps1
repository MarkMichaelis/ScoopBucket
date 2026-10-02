<#
.SYNOPSIS
    Light-suite Pester coverage for the MarkMichaelis tool configuration imports
    (Import-WindowsTerminalSettings, Import-ClaudeCodeSettings; #412).

.DESCRIPTION
    Pins the desired-state contract both ConfigScripts rely on. Every target path is
    redirected into TestDrive, each import runs twice, and the second run must change
    nothing while the user's unrelated settings, hooks, and profile lines survive.
#>

BeforeAll {
    Import-Module (Resolve-Path (Join-Path $PSScriptRoot '..\MarkMichaelis.ScoopBucket.psd1')) -Force
    $script:bucketDir = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\bucket')
    $script:wtConfig = Join-Path $script:bucketDir 'os\MarkMichaelisWindowsTerminalSettings.jsonc'
    $script:claudeConfig = Join-Path $script:bucketDir 'ai\MarkMichaelisClaudeCodeSettings.jsonc'

    function Invoke-WtImport {
        param([Parameter(Mandatory)][string]$Root, [switch]$NoGitBash, [switch]$WhatIf)
        $gitBash = Join-Path $Root 'Git\bin\bash.exe'
        if (-not $NoGitBash -and -not $WhatIf) { New-Item -ItemType File -Path $gitBash -Force | Out-Null }
        Import-WindowsTerminalSettings -ConfigPath $script:wtConfig `
            -SettingsPath (Join-Path $Root 'wt\settings.json') -ClaudeHome (Join-Path $Root '.claude') `
            -ProfilePath (Join-Path $Root 'profile.ps1') -BashrcPath (Join-Path $Root '.bashrc') `
            -BashProfilePath (Join-Path $Root '.bash_profile') -GitBashPath $gitBash -WhatIf:$WhatIf `
            -LegacyTabsDir (Join-Path $Root 'legacy')
    }

    function Invoke-ClaudeImport {
        param([Parameter(Mandatory)][string]$Root, [switch]$WhatIf)
        Import-ClaudeCodeSettings -ConfigPath $script:claudeConfig -ClaudeHome (Join-Path $Root '.claude') -WhatIf:$WhatIf
    }

    function Read-TestJson([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable }

    function Set-TestFile([string]$Path, [string]$Text) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        Set-Content -LiteralPath $Path -Value $Text
    }
}

Describe 'Import-WindowsTerminalSettings' -Tag 'Light', 'Module' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root | Out-Null
        $script:wt = Join-Path $script:root 'wt\settings.json'
    }

    It 'merges the committed settings, keeps unrelated ones, and changes nothing on a second run' {
        Set-TestFile $script:wt '{ "defaultProfile": "{abc}", "keybindings": [ { "id": "User.copy", "keys": "ctrl+c" } ], "profiles": { "list": [ { "guid": "{abc}", "name": "PowerShell" } ] }, "themes": [ { "name": "Other" } ] }'

        $first = Invoke-WtImport -Root $script:root
        $second = Invoke-WtImport -Root $script:root

        $first.Changed | Should -Contain 'Windows Terminal settings'
        $second.Changed | Should -BeNullOrEmpty
        $s = Read-TestJson $script:wt
        $s['firstWindowPreference'] | Should -Be 'persistedWindowLayout'
        $s['startOnUserLogin'] | Should -BeTrue
        $s['theme'] | Should -Be 'Claude Tabs'
        @($s['themes'] | ForEach-Object { $_['name'] }) | Should -Be @('Other', 'Claude Tabs')
        $s['defaultProfile'] | Should -Be '{abc}'
        $s['keybindings'][0]['keys'] | Should -Be 'ctrl+c'
        @($s['profiles']['list'] | ForEach-Object { $_['name'] }) | Should -Be @('PowerShell', 'Git Bash')
        ($s['profiles']['list'] | Where-Object { $_['name'] -eq 'Git Bash' })['commandline'] | Should -BeLike '*Git\bin\bash.exe" --login -i'
    }

    It 'keeps a Git Bash profile the user already has instead of adding another' {
        Set-TestFile $script:wt '{ "profiles": { "list": [ { "guid": "{mine}", "name": "Git Bash", "commandline": "bash" } ] } }'

        Invoke-WtImport -Root $script:root | Out-Null

        $gitBash = @((Read-TestJson $script:wt)['profiles']['list'] | Where-Object { $_['name'] -eq 'Git Bash' })
        $gitBash.Count | Should -Be 1
        $gitBash[0]['guid'] | Should -Be '{mine}'
    }

    It 'creates the settings file when Windows Terminal has not written one yet' {
        Invoke-WtImport -Root $script:root | Out-Null

        $s = Read-TestJson $script:wt
        $s['$schema'] | Should -Not -BeNullOrEmpty
        $s['firstWindowPreference'] | Should -Be 'persistedWindowLayout'
    }

    It 'installs the shell integration, with LF-only line endings for bash' {
        Invoke-WtImport -Root $script:root | Out-Null

        $scripts = Join-Path $script:root '.claude\scripts'
        foreach ($name in 'ClaudeTabs.psm1', 'claude-tabs.js', 'claude-tabs.bash') { Join-Path $scripts $name | Should -Exist }
        [System.IO.File]::ReadAllText((Join-Path $scripts 'claude-tabs.bash')) | Should -Not -Match "`r"
    }

    It 'replaces the profile and .bashrc lines an earlier install wrote, in place, then removes its scripts' {
        $profilePath = Join-Path $script:root 'profile.ps1'
        Set-TestFile $profilePath (@(
                'Import-Module posh-git'
                '# Windows Terminal: color tabs by repo; resume Claude sessions in tabs restored after a crash or reboot'
                '$claudeTabsModule = Join-Path $env:LOCALAPPDATA ''WindowsTerminalTabs\ClaudeTabs.psm1'''
                'if (Test-Path $claudeTabsModule) { Import-Module $claudeTabsModule; Invoke-ClaudeTabRestore }'
                'Remove-Variable claudeTabsModule'
                'Import-Module Other'
            ) -join "`r`n")
        [System.IO.File]::WriteAllText((Join-Path $script:root '.bashrc'), (@(
                'alias ll=ls'
                '# Windows Terminal: color tabs by repo; resume Claude sessions in tabs restored after a crash or reboot'
                '_wtt="$(cygpath -u "$LOCALAPPDATA")/WindowsTerminalTabs/claude-tabs.bash"; [ -f "$_wtt" ] && . "$_wtt"; unset _wtt'
                ''
            ) -join "`n"))
        foreach ($name in 'ClaudeTabs.psm1', 'claude-tabs.js', 'claude-tabs.bash') { Set-TestFile (Join-Path $script:root "legacy\$name") 'old' }

        $first = Invoke-WtImport -Root $script:root
        $second = Invoke-WtImport -Root $script:root

        $first.Changed | Should -Contain 'PowerShell profile'
        $first.Changed | Should -Contain '.bashrc'
        $first.Changed | Should -Contain 'obsolete tab scripts'
        $second.Changed | Should -BeNullOrEmpty
        $profileLines = Get-Content -LiteralPath $profilePath
        $profileLines.Count | Should -Be 6
        $profileLines[0] | Should -Be 'Import-Module posh-git'
        $profileLines[2] | Should -Be '$claudeTabsModule = Join-Path $HOME ''.claude\scripts\ClaudeTabs.psm1'''
        $profileLines[5] | Should -Be 'Import-Module Other'
        $bashrc = [System.IO.File]::ReadAllText((Join-Path $script:root '.bashrc'))
        $bashrc | Should -Not -Match 'WindowsTerminalTabs|\r'
        @($bashrc -split "`n" | Where-Object { $_ -match 'claude-tabs\.bash' }).Count | Should -Be 1
        $bashrc | Should -Match '^alias ll=ls\n'
        Join-Path $script:root 'legacy' | Should -Not -Exist
    }

    It 'keeps the earlier install''s scripts while a startup file still loads them' {
        Set-TestFile (Join-Path $script:root '.bashrc') '_wtt="$(cygpath -u "$LOCALAPPDATA")/WindowsTerminalTabs/claude-tabs.bash"'
        Set-TestFile (Join-Path $script:root 'legacy\claude-tabs.bash') 'old'

        Invoke-WtImport -Root $script:root -NoGitBash | Out-Null

        Join-Path $script:root 'legacy\claude-tabs.bash' | Should -Exist
    }

    It 'adds the profile import and the bash source line exactly once' {
        Set-TestFile (Join-Path $script:root 'profile.ps1') 'Import-Module posh-git'

        Invoke-WtImport -Root $script:root | Out-Null
        $second = Invoke-WtImport -Root $script:root

        $second.Changed | Should -BeNullOrEmpty
        $profileLines = Get-Content -LiteralPath (Join-Path $script:root 'profile.ps1')
        $profileLines[0] | Should -Be 'Import-Module posh-git'
        @($profileLines | Where-Object { $_ -match 'ClaudeTabs\.psm1' }).Count | Should -Be 1
        $bashrc = [System.IO.File]::ReadAllText((Join-Path $script:root '.bashrc'))
        @($bashrc -split "`n" | Where-Object { $_ -match 'claude-tabs\.bash' }).Count | Should -Be 1
        $bashrc | Should -Not -Match "`r"
        [System.IO.File]::ReadAllText((Join-Path $script:root '.bash_profile')) | Should -Match '\. ~/\.bashrc'
    }

    It 'leaves an existing ~/.bash_profile alone' {
        Set-TestFile (Join-Path $script:root '.bash_profile') 'echo mine'

        Invoke-WtImport -Root $script:root | Out-Null

        (Get-Content -LiteralPath (Join-Path $script:root '.bash_profile') -Raw).Trim() | Should -Be 'echo mine'
    }

    It 'skips the Git Bash profile and bash files when Git for Windows is absent' {
        Invoke-WtImport -Root $script:root -NoGitBash | Out-Null

        (Read-TestJson $script:wt).Contains('profiles') | Should -BeFalse
        Join-Path $script:root '.bashrc' | Should -Not -Exist
        Join-Path $script:root '.bash_profile' | Should -Not -Exist
    }

    It 'writes nothing under -WhatIf' {
        Invoke-WtImport -Root $script:root -WhatIf | Out-Null

        @(Get-ChildItem -LiteralPath $script:root -Recurse -File).Count | Should -Be 0
    }
}

Describe 'Import-ClaudeCodeSettings' -Tag 'Light', 'Module' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root | Out-Null
        $script:settings = Join-Path $script:root '.claude\settings.json'
    }

    It 'sets the theme and output style, adds the hook once, and keeps other settings and hooks' {
        Set-TestFile $script:settings '{ "model": "opus", "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "echo other" } ] } ] } }'

        $first = Invoke-ClaudeImport -Root $script:root
        $second = Invoke-ClaudeImport -Root $script:root

        $first.Changed | Should -Contain 'Claude Code settings'
        $second.Changed | Should -BeNullOrEmpty
        $s = Read-TestJson $script:settings
        $s['model'] | Should -Be 'opus'
        $s['theme'] | Should -Be 'custom:prompt-spotlight'
        $s['outputStyle'] | Should -Be 'Outcomes, not code'
        @($s['hooks']['SessionStart']).Count | Should -Be 2
        $s['hooks']['SessionStart'][0]['hooks'][0]['command'] | Should -Be 'echo other'
        @($s['hooks']['SessionEnd']).Count | Should -Be 1
        $s['hooks']['SessionEnd'][0]['hooks'][0]['command'] | Should -BeLike 'node "*\.claude\scripts\tab-session-hook.js"'
    }

    It 'recognizes an existing tab-session hook even at another path' {
        Set-TestFile $script:settings '{ "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "node \"D:\\elsewhere\\tab-session-hook.js\"" } ] } ] } }'

        Invoke-ClaudeImport -Root $script:root | Out-Null

        @((Read-TestJson $script:settings)['hooks']['SessionStart']).Count | Should -Be 1
    }

    It 'installs the hook, theme, and output style, and creates settings when missing' {
        Invoke-ClaudeImport -Root $script:root | Out-Null

        $claudeHome = Join-Path $script:root '.claude'
        Join-Path $claudeHome 'scripts\tab-session-hook.js' | Should -Exist
        Join-Path $claudeHome 'output-styles\outcomes-not-code.md' | Should -Exist
        $theme = Read-TestJson (Join-Path $claudeHome 'themes\prompt-spotlight.json')
        $theme['name'] | Should -Be 'Prompt Spotlight'
        $theme['overrides']['userMessageBackground'] | Should -Not -BeNullOrEmpty
        (Read-TestJson $script:settings)['theme'] | Should -Be 'custom:prompt-spotlight'
    }

    It 'writes nothing under -WhatIf' {
        Invoke-ClaudeImport -Root $script:root -WhatIf | Out-Null

        @(Get-ChildItem -LiteralPath $script:root -Recurse -File).Count | Should -Be 0
    }
}

Describe 'Committed MarkMichaelis terminal configuration assets' -Tag 'Light', 'Module' {
    It 'parses both configurations' {
        (Read-TestJson $script:wtConfig)['settings']['theme'] | Should -Be 'Claude Tabs'
        (Read-TestJson $script:claudeConfig)['settings']['outputStyle'] | Should -Be 'Outcomes, not code'
    }

    It 'ships a tab module that parses cleanly' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:bucketDir 'os\MarkMichaelisClaudeTabs.psm1'), [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
}
