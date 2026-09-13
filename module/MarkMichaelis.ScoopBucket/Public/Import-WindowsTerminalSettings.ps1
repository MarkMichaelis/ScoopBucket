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
          * Installs the tab shell integration into ~/.claude/scripts: per-repository
            tab colors and Claude session resume, for PowerShell and Git Bash.
            Seeds the tab color map without overwriting local entries, then adds
            one guarded import to the PowerShell profile and one guarded source
            line to ~/.bashrc (creating ~/.bash_profile to load it when missing).

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
        Folder receiving the scripts and the tab color map (defaults to ~/.claude).
    .PARAMETER ProfilePath
        PowerShell profile that imports the tab module (defaults to $PROFILE).
    .PARAMETER BashrcPath
        Git Bash startup file that sources the bash integration (defaults to ~/.bashrc).
    .PARAMETER BashProfilePath
        Git Bash login file, created to load ~/.bashrc when missing (defaults to ~/.bash_profile).
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
        [string]$GitBashPath = (Join-Path $env:ProgramFiles 'Git\bin\bash.exe')
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

    $colorsPath = Join-Path $ClaudeHome 'terminal-tabs\colors.json'
    $colors = Read-JsonSettingsFile -Path $colorsPath
    $localRepos = @($colors.Keys | ForEach-Object { $_.ToLowerInvariant() })
    foreach ($repo in $config['tabColors'].Keys) {
        if ($repo.ToLowerInvariant() -notin $localRepos) { $colors[$repo.ToLowerInvariant()] = $config['tabColors'][$repo] }
    }
    if (Write-JsonSettingsFile -Path $colorsPath -Settings $colors -Action 'Seed tab colors') {
        $changed.Add('tab colors')
    }

    if ($ProfilePath) {
        $profileLines = @(
            '# Windows Terminal: color tabs by repo; resume Claude sessions in tabs restored after a crash or reboot'
            '$claudeTabsModule = Join-Path $HOME ''.claude\scripts\ClaudeTabs.psm1'''
            'if (Test-Path $claudeTabsModule) { Import-Module $claudeTabsModule; Invoke-ClaudeTabRestore }'
            'Remove-Variable claudeTabsModule'
        )
        if (Add-LinesIfMissing -Path $ProfilePath -Match 'ClaudeTabs.psm1' -Lines $profileLines) {
            $changed.Add('PowerShell profile')
        }
    }

    if ($hasGitBash) {
        $bashLines = @(
            '# Windows Terminal: color tabs by repo; resume Claude sessions in tabs restored after a crash or reboot'
            '[ -f "$HOME/.claude/scripts/claude-tabs.bash" ] && . "$HOME/.claude/scripts/claude-tabs.bash"'
        )
        if (Add-LinesIfMissing -Path $BashrcPath -Match 'claude-tabs.bash' -Lines $bashLines -LfLineEndings) {
            $changed.Add('.bashrc')
        }
        # Git Bash starts a login shell, which reads ~/.bash_profile, not ~/.bashrc.
        # An existing ~/.bash_profile is the user's; leave it alone.
        if (-not (Test-Path -LiteralPath $BashProfilePath) -and
            (Add-LinesIfMissing -Path $BashProfilePath -Match '.bashrc' -Lines @('[ -f ~/.bashrc ] && . ~/.bashrc') -LfLineEndings)) {
            $changed.Add('.bash_profile')
        }
    }

    [pscustomobject]@{
        SettingsPath = $SettingsPath
        Changed      = $changed.ToArray()
    }
}
