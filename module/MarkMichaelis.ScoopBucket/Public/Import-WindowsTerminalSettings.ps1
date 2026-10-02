function Import-WindowsTerminalSettings {
    <#
    .SYNOPSIS
        Apply the committed MarkMichaelis Windows Terminal configuration.
    .DESCRIPTION
        Desired-state configuration run as the Windows Terminal package
        ConfigScript (#412), so it is re-applied on every install and update and
        is idempotent -- a re-run changes nothing:

          * Merges the committed settings into Windows Terminal's settings.json:
            reopen windows and tabs after a reboot or crash, start at sign-in, and
            the "Claude Tabs" theme. Adds a Git Bash profile when Git for Windows is
            installed and no profile of that name exists. Every other setting is
            kept, and the file is rewritten only when something changed.
          * Installs the tab shell integration into ~/.claude/scripts: tab colors
            per root folder (repository, home, or marked with Set-ClaudeTabRoot)
            and Claude session resume, for PowerShell and Git Bash. Adds one
            guarded import to the PowerShell profile and one guarded source line
            to ~/.bashrc (creating ~/.bash_profile to load it when missing). Lines
            an earlier install wrote for scripts in %LOCALAPPDATA%\WindowsTerminalTabs
            are replaced in place, and those obsolete scripts are then removed.

        The committed configuration lives in the bucket, so the ConfigScript in
        OSBasePackages.ps1 passes an explicit -ConfigPath resolved from its own
        $PSScriptRoot; the default resolves the same file when the module is
        imported from the repo. Honours -WhatIf.
    .PARAMETER ConfigPath
        The committed configuration (MarkMichaelisWindowsTerminalSettings.jsonc).
        The shell-integration scripts are read from the same folder.
    .PARAMETER SettingsPath
        Windows Terminal settings.json (defaults to the installed Terminal's).
    .PARAMETER ClaudeHome
        Folder receiving the scripts (defaults to ~/.claude). The tab color map roams
        in <OneDrive>\Documents\WindowsTerminalTabs and is managed by the module.
    .PARAMETER ProfilePath
        PowerShell profile that imports the tab module (defaults to $PROFILE).
    .PARAMETER BashrcPath
        Git Bash startup file that sources the bash integration (defaults to ~/.bashrc).
    .PARAMETER BashProfilePath
        Git Bash login file, created to load ~/.bashrc when missing (defaults to ~/.bash_profile).
    .PARAMETER LegacyTabsDir
        Where an earlier install put the tab scripts; removed once nothing loads them.
    .PARAMETER GitBashPath
        Git for Windows bash.exe; the Git Bash pieces are skipped when it is absent.
    .OUTPUTS
        PSCustomObject -- SettingsPath, Changed (the items written on this run).
    .EXAMPLE
        Import-WindowsTerminalSettings -WhatIf
        Shows what would change without writing anything.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$ConfigPath = (Join-Path $PSScriptRoot '..\..\..\bucket\os\MarkMichaelisWindowsTerminalSettings.jsonc'),
        [string]$SettingsPath = (Get-WindowsTerminalSettingsPath),
        [string]$ClaudeHome = (Join-Path $HOME '.claude'),
        [string]$ProfilePath = $PROFILE,
        [string]$BashrcPath = (Join-Path $HOME '.bashrc'),
        [string]$BashProfilePath = (Join-Path $HOME '.bash_profile'),
        [string]$GitBashPath = (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        [string]$LegacyTabsDir = (Join-Path $env:LOCALAPPDATA 'WindowsTerminalTabs')
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Windows Terminal configuration not found: $ConfigPath"
    }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $assetDir = Split-Path -Parent $ConfigPath
    $hasGitBash = $GitBashPath -and (Test-Path -LiteralPath $GitBashPath -PathType Leaf)
    $changed = [System.Collections.Generic.List[string]]::new()

    # Windows Terminal settings.json
    $settings = Read-JsonSettingsFile -Path $SettingsPath
    if ($settings.Count -eq 0) { $settings['$schema'] = 'https://aka.ms/terminal-profiles-schema' }
    foreach ($key in $config['settings'].Keys) { $settings[$key] = $config['settings'][$key] }

    $ourThemes = @($config['themes'])
    $ourThemeNames = @($ourThemes | ForEach-Object { $_['name'] })
    $keptThemes = @($settings['themes'] | Where-Object { $_ -and $_['name'] -notin $ourThemeNames })
    $settings['themes'] = @($keptThemes) + $ourThemes

    if ($hasGitBash) {
        $profiles = $settings['profiles']
        if ($null -eq $profiles) {
            $profiles = [ordered]@{ list = @() }
            $settings['profiles'] = $profiles
        }
        # @() around the whole if: a statement's output unrolls a one-element array.
        $list = @(if ($profiles -is [System.Collections.IDictionary]) { $profiles['list'] } else { $profiles }) | Where-Object { $_ }
        $list = @($list)
        $gitBash = $config['gitBashProfile']
        if (-not ($list | Where-Object { $_['name'] -eq $gitBash['name'] })) {
            $entry = [ordered]@{}
            foreach ($key in $gitBash.Keys) { $entry[$key] = $gitBash[$key] }
            $entry['commandline'] = '"{0}" --login -i' -f $GitBashPath
            $icon = Join-Path (Split-Path (Split-Path $GitBashPath -Parent) -Parent) 'mingw64\share\git\git-for-windows.ico'
            if (Test-Path -LiteralPath $icon -PathType Leaf) { $entry['icon'] = $icon }
            $list += , $entry
            if ($profiles -is [System.Collections.IDictionary]) { $profiles['list'] = $list } else { $settings['profiles'] = $list }
        }
    }
    if (Write-JsonSettingsFile -Path $SettingsPath -Settings $settings -Action 'Apply Windows Terminal settings') {
        $changed.Add('Windows Terminal settings')
    }

    # Tab shell integration
    $scriptsDir = Join-Path $ClaudeHome 'scripts'
    $scripts = [ordered]@{
        'MarkMichaelisClaudeTabs.psm1' = 'ClaudeTabs.psm1'
        'MarkMichaelisClaudeTabs.js'   = 'claude-tabs.js'
        'MarkMichaelisClaudeTabs.bash' = 'claude-tabs.bash'
    }
    foreach ($source in $scripts.Keys) {
        $isBash = $source -like '*.bash'
        if (Copy-FileIfChanged -Source (Join-Path $assetDir $source) -Destination (Join-Path $scriptsDir $scripts[$source]) -LfLineEndings:$isBash) {
            $changed.Add($scripts[$source])
        }
    }

    $comment = '# Windows Terminal: color tabs by root folder (repo, home, or marked); resume Claude sessions in tabs restored after a crash or reboot'
    # Lines an earlier install (scripts in %LOCALAPPDATA%\WindowsTerminalTabs) wrote.
    $staleComment = '^\s*# Windows Terminal: color tabs by '
    if ($ProfilePath) {
        $profileLines = @(
            $comment
            '$claudeTabsModule = Join-Path $HOME ''.claude\scripts\ClaudeTabs.psm1'''
            'if (Test-Path $claudeTabsModule) { Import-Module $claudeTabsModule; Invoke-ClaudeTabRestore }'
            'Remove-Variable claudeTabsModule'
        )
        $repaired = Repair-StaleLines -Path $ProfilePath -Stale 'WindowsTerminalTabs\\ClaudeTabs\.psm1' -Lines $profileLines -Companion @(
            $staleComment, '^\s*\$claudeTabsModule = ', '^\s*if \(Test-Path \$claudeTabsModule\)', '^\s*Remove-Variable claudeTabsModule\s*$')
        if ($repaired -or (Add-LinesIfMissing -Path $ProfilePath -Match 'ClaudeTabs.psm1' -Lines $profileLines)) {
            $changed.Add('PowerShell profile')
        }
    }

    if ($hasGitBash) {
        $bashLines = @(
            $comment
            '[ -f "$HOME/.claude/scripts/claude-tabs.bash" ] && . "$HOME/.claude/scripts/claude-tabs.bash"'
        )
        $repaired = Repair-StaleLines -Path $BashrcPath -Stale 'WindowsTerminalTabs/claude-tabs\.bash' -Lines $bashLines -LfLineEndings -Companion @(
            $staleComment, 'claude-tabs\.bash')
        if ($repaired -or (Add-LinesIfMissing -Path $BashrcPath -Match 'claude-tabs.bash' -Lines $bashLines -LfLineEndings)) {
            $changed.Add('.bashrc')
        }
        # Git Bash starts a login shell, which reads ~/.bash_profile, not ~/.bashrc.
        # An existing ~/.bash_profile is the user's; leave it alone.
        if (-not (Test-Path -LiteralPath $BashProfilePath) -and
            (Add-LinesIfMissing -Path $BashProfilePath -Match '.bashrc' -Lines @('[ -f ~/.bashrc ] && . ~/.bashrc') -LfLineEndings)) {
            $changed.Add('.bash_profile')
        }
    }

    # The earlier install's scripts, once nothing loads them any more.
    if ($LegacyTabsDir -and (Test-Path -LiteralPath $LegacyTabsDir -PathType Container)) {
        $stillLoaded = foreach ($startup in $ProfilePath, $BashrcPath) {
            if ($startup -and (Test-Path -LiteralPath $startup -PathType Leaf) -and
                [System.IO.File]::ReadAllText($startup) -match 'WindowsTerminalTabs[\\/](ClaudeTabs\.psm1|claude-tabs\.bash)') { $startup }
        }
        if (-not $stillLoaded) {
            $legacy = @('ClaudeTabs.psm1', 'claude-tabs.js', 'claude-tabs.bash' | ForEach-Object { Join-Path $LegacyTabsDir $_ } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
            if ($legacy -and $PSCmdlet.ShouldProcess($LegacyTabsDir, 'Remove the obsolete tab scripts')) {
                Remove-Item -LiteralPath $legacy -Force
                if (-not (Get-ChildItem -LiteralPath $LegacyTabsDir -Force)) { Remove-Item -LiteralPath $LegacyTabsDir -Force }
                $changed.Add('obsolete tab scripts')
            }
        }
    }

    [pscustomobject]@{
        SettingsPath = $SettingsPath
        Changed      = $changed.ToArray()
    }
}
