$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

# Refs:
#   #29  ffmpeg via scoop main rather than winget Gyan.FFmpeg (nested-installer drift)
#   #43  ripgrep via scoop main (v14+) so `rg --generate complete-powershell` works
#   #44  procexp / sysinternals via scoop extras (winget hash drift)
#   #73  rg native completion + gcloud PSCompletions fallback

$Packages = [Package[]]@(
    [Package]@{ Name = 'Windows Terminal';              Installer = 'winget'; Id = 'Microsoft.WindowsTerminal';                          CliCommands = @('wt') }
    [Package]@{ Name = '7-Zip';                         Installer = 'winget'; Id = '7Zip.7Zip';                                          CliCommands = @('7z') }
    [Package]@{ Name = 'Everything';                    Installer = 'winget'; Id = 'voidtools.Everything' }
    [Package]@{ Name = 'Everything CLI';                Installer = 'winget'; Id = 'voidtools.Everything.Cli';                           CliCommands = @('es') }
    [Package]@{ Name = 'Google Chrome';                 Installer = 'winget'; Id = 'Google.Chrome' }
    [Package]@{ Name = 'WinDirStat';                    Installer = 'winget'; Id = 'WinDirStat.WinDirStat' }
    [Package]@{ Name = 'UniversalSilentSwitchFinder';   Installer = 'winget'; Id = 'WindowsPostInstallWizard.UniversalSilentSwitchFinder' }
    [Package]@{ Name = 'bat';                           Installer = 'winget'; Id = 'sharkdp.bat';                                        CliCommands = @('bat') }
    [Package]@{ Name = 'fzf';                           Installer = 'winget'; Id = 'junegunn.fzf';                                       CliCommands = @('fzf') }
    [Package]@{ Name = 'Google Cloud SDK';              Installer = 'winget'; Id = 'Google.CloudSDK';                                    CliCommands = @('gcloud'); Completion = 'pscompletions' }

    # Editor included in the OS baseline so a freshly imaged box has a
    # text editor available before DeveloperBasePackages runs. The winget
    # engine's AlreadyInstalled probe makes the duplicate declaration in
    # DeveloperBasePackages a no-op on a second pass.
    [Package]@{ Name = 'Visual Studio Code';            Installer = 'winget'; Id = 'Microsoft.VisualStudioCode';                          CliCommands = @('code') }

    # scoop replacements for winget entries with upstream drift
    [Package]@{ Name = 'ffmpeg';                        Installer = 'scoop';  Id = 'main/ffmpeg';                                         CliCommands = @('ffmpeg') }
    [Package]@{
        Name        = 'ripgrep'
        Installer   = 'scoop'
        Id          = 'main/ripgrep'
        CliCommands = @('rg')
        Completion  = 'native'
        NativeCommandScript = { rg --generate complete-powershell }
        Notes       = 'scoop main/ripgrep gives v14+, required for --generate complete-powershell. See #73.'
    }
    [Package]@{
        Name        = 'Sysinternals Suite'
        Installer   = 'scoop'
        Id          = 'extras/sysinternals'
        Notes       = 'extras/sysinternals declares every tool in its manifest "bin" list, so scoop creates a shim per tool (procexp, autoruns, accesschk, ...) automatically. No PATH update required. See #44.'
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'OSBasePackages'
