$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

# Refs:
#   #5/#6/#7/#10/#12  scoop extras for apps with no machine-scope winget installer
#   #8/#46            Pushbullet: no maintained installer; CISkip
#   #9/#11            Snagit / Todoist via Microsoft Store (winget --source msstore)
#   #13/#46           DbxCli delisted from choco; install via local bucket manifest
#   #27               foxitreader choco package times out; use winget
#   #73               bw / gcloud have no PSCompletions catalog entry — ship our own native completer

$Packages = [Package[]]@(
    [Package]@{
        Name        = 'exiftool'
        Installer   = 'choco'
        Id          = 'exiftool'
        CliCommands = @('exiftool')
        Completion  = 'auto'
        Notes       = 'exiftool has no completion subcommand and no PSCompletions entry. Hand-curated common-options list (full surface is ~500 tag names).'
        ExpectedCompletions = @{ exiftool = @('-help','-overwrite_original','-r') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName exiftool -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '-help','-ver','-r','-q','-quiet','-overwrite_original','-overwrite_original_in_place',
        '-preserve','-P','-ext','-ee','-G','-a','-s','-S','-T','-csv','-json','-xml','-html',
        '-args','-charset','-d','-list','-listw','-listf','-listg','-listr','-listx',
        '-Filename','-Directory','-FileModifyDate','-Comment','-Keywords','-Subject','-Title'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
    [Package]@{ Name = 'GeoSetter';        Installer = 'choco';  Id = 'geosetter' }

    [Package]@{
        Name        = 'DbxCli'
        Installer   = 'scoop'
        Id          = 'MarkMichaelis/DbxCli'
        CliCommands = @('dbxcli')
        Completion  = 'auto'
        Notes       = 'dbxcli delisted from chocolatey (#13). Installed via this bucket''s DbxCli.json which pulls upstream GitHub release. dbxcli is a cobra-based tool but ships no completion subcommand; hand-curate the top-level command list.'
        ExpectedCompletions = @{ dbxcli = @('get','put','ls') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName dbxcli -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        'account','du','get','ls','mkdir','mv','put','restore','revs','rm','search','share',
        'team','version','help','--help','-h'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }

    [Package]@{ Name = 'AIAgents bundle';  Installer = 'scoop';  Id = 'MarkMichaelis/AIAgents'
                Notes = 'Pulls every AI agent + Claude Desktop and configures MCP servers; see AIAgents.ps1.' }

    [Package]@{ Name = 'Handy';            Installer = 'winget'; Id = 'cjpais.Handy'; Scope = 'user'
                WingetExtraArgs = @('--skip-dependencies')
                Notes = 'Free open-source local speech-to-text (https://handy.computer). Runs Whisper/Parakeet locally; no cloud. User-scope only. Declares a KhronosGroup.VulkanRT dependency winget cannot resolve on most machines (already present via GPU drivers), so we skip dependency processing.' }

    [Package]@{
        Name        = 'eSpeak NG'
        Installer   = 'scoop'
        Id          = 'main/espeak-ng'
        CliCommands = @('espeak-ng')
        Completion  = 'auto'
        Notes       = 'espeak-ng has no completion subcommand and no PSCompletions entry. Hand-curated flag list.'
        ExpectedCompletions = @{ 'espeak-ng' = @('--help','-v','-s') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName espeak-ng -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','--version','-v','-s','-p','-a','-g','-k','-l','-f','-w','-x','-X','-q','-m',
        '-b','--stdin','--stdout','--pho','--phonout','--punct','--split','--path','--ipa',
        '--voices','--compile','--compile-debug'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
    [Package]@{ Name = 'Notion';           Installer = 'scoop';  Id = 'extras/notion' }
    [Package]@{ Name = 'Spotify';          Installer = 'scoop';  Id = 'extras/spotify' }
    [Package]@{ Name = 'Zoom';             Installer = 'scoop';  Id = 'extras/zoom' }

    [Package]@{ Name = 'Amazon Kindle';    Installer = 'winget'; Id = 'Amazon.Kindle' }
    [Package]@{ Name = 'Bitwarden';        Installer = 'winget'; Id = 'Bitwarden.Bitwarden'
                Companions = @('Bitwarden CLI') }
    [Package]@{
        Name        = 'Bitwarden CLI'
        Installer   = 'winget'
        Id          = 'Bitwarden.CLI'
        CliCommands = @('bw')
        Completion  = 'auto'
        DependsOn   = @('Bitwarden')
        Notes       = '`bw completion` only supports zsh and PSCompletions has no `bw` entry; ship a hand-curated top-level subcommand completer (#73).'
        ExpectedCompletions = @{ bw = @('login','logout','sync','list','unlock','status') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName bw -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    `$cmds = @(
        'completion','config','create','delete','device-approval','edit','encode',
        'export','generate','get','help','import','list','lock','login','logout',
        'restore','send','serve','share','status','sync','unlock','update'
    )
    `$cmds | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
    [Package]@{ Name = 'calibre';          Installer = 'winget'; Id = 'calibre.calibre' }
    [Package]@{
        Name        = 'SoX'
        Installer   = 'winget'
        Id          = 'ChrisBagwell.SoX'
        CliCommands = @('sox')
        Completion  = 'auto'
        Notes       = 'sox has no completion subcommand and no PSCompletions entry. Hand-curated common-options list (effect names enumerated via `sox --help-effect` are out of scope).'
        ExpectedCompletions = @{ sox = @('--help','--version','-r') }
        NativeCommandScript = {
            @"
Register-ArgumentCompleter -Native -CommandName sox -ScriptBlock {
    param(`$wordToComplete, `$commandAst, `$cursorPosition)
    @(
        '--help','--help-effect','--help-format','--version','-r','-c','-b','-e','-t','-V','-S',
        '-n','-d','-D','-q','-G','-R','--norm','--combine','--effects-file','--multi-threaded',
        '--no-clobber','--show-progress','--type','--channels','--bits','--rate','--encoding'
    ) | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new(`$_, `$_, 'ParameterValue', `$_)
    }
}
"@
        }
    }
    [Package]@{ Name = 'Dropbox';          Installer = 'winget'; Id = 'Dropbox.Dropbox' }
    [Package]@{ Name = 'PowerToys';        Installer = 'winget'; Id = 'Microsoft.PowerToys'
                Notes = 'Microsoft PowerToys suite; installed for the maintained Mouse Without Borders module (mouse/keyboard/clipboard sharing across machines), which replaces the unmaintained standalone Microsoft.MouseWithoutBorders 2.2.1 build.'
                ConfigScript = { Import-PowerToysSettings -NoRestart } }
    [Package]@{ Name = 'Foxit PDF Reader'; Installer = 'winget'; Id = 'Foxit.FoxitReader'
                Notes = 'choco foxitreader times out downloading upstream installer (#27). winget is preferred per README.' }
    [Package]@{
        Name        = 'Pushbullet'
        Installer   = 'winget'
        Id          = 'Pushbullet.Pushbullet'
        CISkip      = 'No machine-scope installer and no maintained alternative (#8/#46).'
    }
    [Package]@{ Name = 'Signal';           Installer = 'winget'; Id = 'OpenWhisperSystems.Signal'
                Notes = 'Upstream MSI occasionally crashes on the CI runner with ACCESS_VIOLATION (#22/#65/#66/#75); Install-WingetPackage retries up to 3x before reporting failure.' }

    [Package]@{ Name = 'ChatGPT (Store)';  Installer = 'winget'; Id = '9NT1R1C2HH7J'; Source = 'msstore' }
    [Package]@{ Name = 'VPN Unlimited';    Installer = 'winget'; Id = '9NRQBLR605RG'; Source = 'msstore' }
    [Package]@{ Name = 'Grammarly';        Installer = 'winget'; Id = 'XPDDXX9QW8N9D7'; Source = 'msstore' }
    [Package]@{ Name = 'WhatsApp';         Installer = 'winget'; Id = '9NKSQGP7F2NH'; Source = 'msstore' }
    [Package]@{ Name = 'Snagit';           Installer = 'winget'; Id = 'XPDNSF6TXN2R6Z'; Source = 'msstore'
                Notes = 'winget default source ships user-scope MSIX only; ms-store is the automated path (#9).' }
    [Package]@{ Name = 'Todoist';          Installer = 'winget'; Id = '9MWF2DWS5Z9N'; Source = 'msstore'
                Notes = 'winget default source ships user-scope MSIX only; ms-store is the automated path (#11). The sachaos/todoist CLI companion was removed in #326 because Sachaos.Todoist was delisted from winget (confirmed on CI, #325).' }

    [Package]@{
        Name        = 'Readwise Reader'
        Installer   = 'custom'
        Notes       = 'Sideloaded MSIX; not in winget or Microsoft Store.'
        UpdateMode  = 'Reinstall'  # re-run the idempotent download-latest MSIX install; VerifyScript gates it.
        CustomInstallScript = {
            $tmp = Join-Path $env:TEMP 'ReadwiseReader.msix'
            Invoke-WebRequest -Uri 'https://readwise.io/read/download_latest/desktop/windows' -OutFile $tmp
            try { Add-AppxPackage -Path $tmp } finally { Remove-Item $tmp -ErrorAction Ignore }
        }
        VerifyScript = { [bool](Get-AppxPackage -Name '*Readwise*' -ErrorAction SilentlyContinue) }
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'ClientBasePackages'
