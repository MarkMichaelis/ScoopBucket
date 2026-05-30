$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

# Refs:
#   #29  ffmpeg via scoop main rather than winget Gyan.FFmpeg (nested-installer drift)
#   #43  ripgrep via scoop main (v14+) so `rg --generate complete-powershell` works
#   #44  procexp / sysinternals via scoop extras (winget hash drift)
#   #73  rg native completion + gcloud PSCompletions fallback

$Packages = [Package[]]@(
    [Package]@{
        Name        = 'Windows Terminal'
        Installer   = 'winget'
        Id          = 'Microsoft.WindowsTerminal'
        CliCommands = @('wt')
        Completion  = 'pscompletions'
        ExpectedCompletions = @{ wt = @('new-tab','split-pane','focus-tab') }
    }
    [Package]@{
        Name        = '7-Zip'
        Installer   = 'winget'
        Id          = '7Zip.7Zip'
        CliCommands = @('7z')
        Completion  = 'auto'
        Notes       = '7z has no `7z completion powershell` subcommand; the PSCompletions catalog entry is third-party. Phase 2 of the native-completion migration replaces it with a hand-curated NativeCommandScript covering 7z''s small/stable CLI surface (commands a/b/d/e/h/i/l/rn/t/u/x and the common switches). See #233.'
        ExpectedCompletions = @{ '7z' = @('a','x','l','t','-y') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName 7z -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        'a','b','d','e','h','i','l','rn','t','u','x',
        '-y','-r','-p','-o','-mx','-mx0','-mx1','-mx2','-mx3','-mx4','-mx5','-mx6','-mx7','-mx8','-mx9',
        '-t7z','-tzip','-tgzip','-tbzip2','-ttar','-txz','-twim','-tiso',
        '-aoa','-aos','-aou','-aot','-bd','-bb','-bso','-bse','-bsp',
        '-sdel','-sfx','-si','-so','-spd','-spe','-spf','-ssc','-ssw',
        '-stl','-stx','-slp','-snh','-snl','-snr','-stm','-w','-x','-i'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
    [Package]@{ Name = 'Everything';                    Installer = 'winget'; Id = 'voidtools.Everything'
                Companions = @('Everything CLI') }
    [Package]@{
        Name        = 'Everything CLI'
        Installer   = 'winget'
        Id          = 'voidtools.Everything.Cli'
        CliCommands = @('es')
        Completion  = 'auto'
        Notes       = 'es.exe has no PowerShell completion subcommand and no PSCompletions catalog entry; ship hand-curated top-level flags so Tab returns the common search-control switches.'
        ExpectedCompletions = @{ es = @('-s','-r','-n','-sort','-help') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName es -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '-s','-r','-i','-w','-p','-c','-n','-sort','-name','-path','-size','-date-modified',
        '-date-created','-attributes','-r-name','-r-path','-help','-export-csv','-export-txt',
        '-folder','-file','-instance','-set-run-count','-inc-run-count'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
    [Package]@{ Name = 'Google Chrome';                 Installer = 'winget'; Id = 'Google.Chrome' }
    [Package]@{ Name = 'WinDirStat';                    Installer = 'winget'; Id = 'WinDirStat.WinDirStat' }
    [Package]@{ Name = 'UniversalSilentSwitchFinder';   Installer = 'winget'; Id = 'WindowsPostInstallWizard.UniversalSilentSwitchFinder' }
    [Package]@{
        Name        = 'bat'
        Installer   = 'winget'
        Id          = 'sharkdp.bat'
        CliCommands = @('bat')
        Completion  = 'auto'
        Notes       = 'bat ships zsh/bash/fish completion only; no PowerShell command and no PSCompletions entry. Hand-curated top-level flag list.'
        ExpectedCompletions = @{ bat = @('--help','--list-languages','--style') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName bat -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','--version','--list-languages','--list-themes','--language','--theme',
        '--style','--paging','--color','--decorations','--wrap','--tabs','--line-range',
        '--show-all','--plain','--number','--cache-build','--diff','--diff-context'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
    [Package]@{
        Name        = 'fzf'
        Installer   = 'winget'
        Id          = 'junegunn.fzf'
        CliCommands = @('fzf')
        Completion  = 'auto'
        Notes       = 'fzf ships shell-key-binding completion for bash/zsh/fish (and a PowerShell PSFzf module) but no native `fzf completion powershell` and no PSCompletions entry. Hand-curated top-level flag list.'
        ExpectedCompletions = @{ fzf = @('--help','--height','--reverse') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName fzf -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','--version','--height','--reverse','--multi','--query','--filter',
        '--preview','--preview-window','--bind','--header','--prompt','--ansi',
        '--no-sort','--exact','--cycle','--layout','--border','--color','--print0',
        '--read0','--info','--scroll-off','--tabstop','--no-mouse'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
    [Package]@{
        Name        = 'Google Cloud SDK'
        Installer   = 'winget'
        Id          = 'Google.CloudSDK'
        CliCommands = @('gcloud')
        Completion  = 'auto'
        Notes       = '`gcloud` has no PowerShell completion command and is not in PSCompletions catalog; ship a hand-curated top-level command-group completer (#73).'
        ExpectedCompletions = @{ gcloud = @('auth','config','version') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName gcloud -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    `$cmds = @(
        'auth','components','config','compute','container','dataflow','dataproc',
        'deployment-manager','dns','functions','iam','init','kms','logging','ml',
        'organizations','projects','pubsub','run','services','source','spanner',
        'sql','storage','topic','version','help'
    )
    `$cmds | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }

    # Editor included in the OS baseline so a freshly imaged box has a
    # text editor available before DeveloperBasePackages runs. The winget
    # engine's AlreadyInstalled probe makes the duplicate declaration in
    # DeveloperBasePackages a no-op on a second pass.
    [Package]@{
        Name        = 'Visual Studio Code'
        Installer   = 'winget'
        Id          = 'Microsoft.VisualStudioCode'
        CliCommands = @('code')
        Completion  = 'auto'
        Notes       = '`code --help` lists CLI switches but `code` has no completion subcommand and no PSCompletions catalog entry. Hand-curated flag list shared with DeveloperBasePackages.'
        ExpectedCompletions = @{ code = @('--help','--diff','--new-window') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName code -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','--version','--diff','--merge','--add','--goto','--new-window','--reuse-window',
        '--wait','--locale','--user-data-dir','--profile','--extensions-dir','--list-extensions',
        '--install-extension','--uninstall-extension','--enable-proposed-api','--status',
        '--prof-startup','--disable-extensions','--disable-extension','--sync','--inspect-extensions',
        '--inspect-brk-extensions','--verbose','--log','--telemetry'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }

    # scoop replacements for winget entries with upstream drift
    [Package]@{
        Name        = 'ffmpeg'
        Installer   = 'scoop'
        Id          = 'main/ffmpeg'
        CliCommands = @('ffmpeg')
        Completion  = 'pscompletions'
        ExpectedCompletions = @{ ffmpeg = @('-i','-y','-version') }
    }
    [Package]@{
        Name        = 'ripgrep'
        Installer   = 'scoop'
        Id          = 'main/ripgrep'
        CliCommands = @('rg')
        Completion  = 'native'
        NativeCommandScript = { rg --generate complete-powershell }
        Notes       = 'scoop main/ripgrep gives v14+, required for --generate complete-powershell. See #73.'
        ExpectedCompletions = @{ rg = @('--help','--version','--color') }
    }
    [Package]@{
        Name        = 'Sysinternals Suite'
        Installer   = 'scoop'
        Id          = 'extras/sysinternals'
        # Curated subset of the 70+ shims extras/sysinternals creates. We
        # only enumerate the tools most commonly used interactively so
        # tab-completion is registered for them. The full set is still on
        # PATH via scoop's shims; users who want completion for additional
        # tools can extend this list.
        CliCommands = @('handle','procexp','autoruns','autorunsc','accesschk','psexec','pslist','sigcheck','procdump','tcpview')
        Completion  = 'native'
        # Sysinternals tools share a small, stable set of universal flags
        # (Win32 conventions: both slash- and dash-prefixed). No upstream
        # PowerShell completer ships for any of them; PSCompletions has
        # no entries either. Emit a per-CLI Register-ArgumentCompleter
        # from this single shared script (Resolve-PackageCompletionSource
        # passes $Cli so the same script generates each tool's block).
        NativeCommandScript = {
            param($Cli)
@"
Register-ArgumentCompleter -Native -CommandName $Cli -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @('/?','-?','/accepteula','-accepteula','/nobanner','-nobanner','/h','-h') |
        Where-Object { `$_ -like "`$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
        }
}
"@
        }
        ExpectedCompletions = @{
            handle     = @('/?','/accepteula','/nobanner')
            procexp    = @('/?','/accepteula','/nobanner')
            autoruns   = @('/?','/accepteula','/nobanner')
            autorunsc  = @('/?','/accepteula','/nobanner')
            accesschk  = @('/?','/accepteula','/nobanner')
            psexec     = @('/?','/accepteula','/nobanner')
            pslist     = @('/?','/accepteula','/nobanner')
            sigcheck   = @('/?','/accepteula','/nobanner')
            procdump   = @('/?','/accepteula','/nobanner')
            tcpview    = @('/?','/accepteula','/nobanner')
        }
        Notes       = 'extras/sysinternals declares every tool in its manifest "bin" list, so scoop creates a shim per tool (procexp, autoruns, accesschk, ...) automatically. No PATH update required. CliCommands enumerates the curated subset that gets tab-completion via a shared per-CLI flag completer (universal Sysinternals flags: /?, /accepteula, /nobanner). See #44.'
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'OSBasePackages'
