. "$PSScriptRoot\Utils.ps1"
Import-Module (Get-ScoopBucketModulePath) -Force

# Refs:
#   #5/#6/#7/#10/#12  scoop extras for apps with no machine-scope winget installer
#   #8/#46            Pushbullet: no maintained installer; CISkip
#   #9/#11            Snagit / Todoist via Microsoft Store (winget --source msstore)
#   #13/#46           DbxCli delisted from choco; install via local bucket manifest
#   #27               foxitreader choco package times out; use winget
#   #73               bw completion only supports zsh -> PSCompletions fallback

$Packages = [Package[]]@(
    [Package]@{ Name = 'exiftool';         Installer = 'choco';  Id = 'exiftool';                                CliCommands = @('exiftool') }
    [Package]@{ Name = 'GeoSetter';        Installer = 'choco';  Id = 'geosetter' }

    [Package]@{ Name = 'DbxCli';           Installer = 'scoop';  Id = 'MarkMichaelis/DbxCli';                    CliCommands = @('dbxcli')
                Notes = 'dbxcli delisted from chocolatey (#13). Installed via this bucket''s DbxCli.json which pulls upstream GitHub release.' }

    [Package]@{ Name = 'AIAgents bundle';  Installer = 'scoop';  Id = 'MarkMichaelis/AIAgents'
                Notes = 'Pulls every AI agent + Claude Desktop and configures MCP servers; see AIAgents.ps1.' }

    [Package]@{ Name = 'eSpeak NG';        Installer = 'scoop';  Id = 'main/espeak-ng';    CliCommands = @('espeak-ng') }
    [Package]@{ Name = 'Notion';           Installer = 'scoop';  Id = 'extras/notion' }
    [Package]@{ Name = 'Spotify';          Installer = 'scoop';  Id = 'extras/spotify' }
    [Package]@{ Name = 'Zoom';             Installer = 'scoop';  Id = 'extras/zoom' }

    [Package]@{ Name = 'Amazon Kindle';    Installer = 'winget'; Id = 'Amazon.Kindle' }
    [Package]@{ Name = 'Bitwarden';        Installer = 'winget'; Id = 'Bitwarden.Bitwarden' }
    [Package]@{
        Name        = 'Bitwarden CLI'
        Installer   = 'winget'
        Id          = 'Bitwarden.CLI'
        CliCommands = @('bw')
        Completion  = 'pscompletions'
        DependsOn   = @('Bitwarden')
        Notes       = '`bw completion` only supports zsh; no native PS completion. PSCompletions fallback (#73).'
    }
    [Package]@{ Name = 'calibre';          Installer = 'winget'; Id = 'calibre.calibre' }
    [Package]@{ Name = 'SoX';              Installer = 'winget'; Id = 'ChrisBagwell.SoX';      CliCommands = @('sox') }
    [Package]@{ Name = 'Dropbox';          Installer = 'winget'; Id = 'Dropbox.Dropbox' }
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
                Notes = 'winget default source ships user-scope MSIX only; ms-store is the automated path (#11).' }

    [Package]@{
        Name        = 'Readwise Reader'
        Installer   = 'custom'
        Notes       = 'Sideloaded MSIX; not in winget or Microsoft Store.'
        CustomInstallScript = {
            $tmp = Join-Path $env:TEMP 'ReadwiseReader.msix'
            Invoke-WebRequest -Uri 'https://readwise.io/read/download_latest/desktop/windows' -OutFile $tmp
            try { Add-AppxPackage -Path $tmp } finally { Remove-Item $tmp -ErrorAction Ignore }
        }
        VerifyScript = { [bool](Get-AppxPackage -Name '*Readwise*' -ErrorAction SilentlyContinue) }
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'ClientBasePackages'
