
Write-Host 'Installing and configuring OSBasePackages...'
. "$PSScriptRoot\Utils.ps1"

$OSPackages = @{
    '7Zip'=([PSCustomObject]@{ WingetName='7-Zip'; WinGetID='7Zip.7Zip';  })
    'Notepad2-mod'=([PSCustomObject]@{ WingetName='Notepad2-mod'; WinGetID=' Notepad2mod.Notepad2mod';  })
    'Everything'=([PSCustomObject]@{ WingetName='Everything'; WinGetID='voidtools.Everything';  })
    'Everything Cli'=([PSCustomObject]@{ WingetName='Everything Cli'; WinGetID='voidtools.Everything.Cli';  })
    'Google Chrome'=([PSCustomObject]@{ WingetName='Google Chrome'; WinGetID='Google.Chrome';  })
    'Process Explorer'=([PSCustomObject]@{ WingetName='Process Explorer'; WinGetID='Microsoft.Sysinternals.ProcessExplorer';  })
    'SysInternals'=([PSCustomObject]@{ WingetName='SysInternals'; WinGetID='Microsoft.SysInternals';  })
    'WinDirStat'=([PSCustomObject]@{ WingetName='WinDirStat'; WinGetID='WinDirStat.WinDirStat';  })
    'UniversalSilentSwitchFinder'=([PSCustomObject]@{ WingetName='UniversalSilentSwitchFinder'; WinGetID='WindowsPostInstallWizard.UniversalSilentSwitchFinder';  })
    'bat'=([PSCustomObject]@{ WingetName='bat'; WinGetID='sharkdp.bat';  }) # Supports Git integration which has not knowingly been configured.
    'BurntSushi.ripgrep.MSVC'=([PSCustomObject]@{ WingetName='Ripgrep'; WinGetID='BurntSushi.ripgrep.MSVC';  }) 
    'fzf'=([PSCustomObject]@{ WingetName='fzf'; WinGetID='junegunn.fzf';  })  # Needs PowerShell install of PSFzf module. See https://github.com/kelleyma49/PSFzf
}

$OSPackages.VAlues | `
    ForEach-Object { 
        Write-Host "Installing $($_.WingetName)..."
        Winget install --id $_.WingetID
    }


