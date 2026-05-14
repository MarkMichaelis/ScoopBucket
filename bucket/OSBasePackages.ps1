. "$PSScriptRoot\Utils.ps1"
Import-Module (Get-ScoopBucketModulePath) -Force

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
        CliCommands = @()
        Notes       = 'extras/sysinternals does not shim individual tools — append the install dir to Machine PATH. See #44.'
        PostInstallScript = {
            try {
                $dir = (& scoop prefix sysinternals 2>$null | Select-Object -First 1)
                if ($dir -and (Test-Path $dir)) {
                    Add-MachinePath -Path $dir -Confirm:$false
                } else {
                    Write-Warning "Could not resolve sysinternals install dir via 'scoop prefix sysinternals'"
                }
            } catch {
                Write-Warning "sysinternals PATH update failed: $($_.Exception.Message)"
            }
        }
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'OSBasePackages'
