
Write-Host 'Installing and configuring OSBasePackages...'
. "$PSScriptRoot\Utils.ps1"

'7zip', 'notepad2', 'Everything', 'es' 'GoogleChrome', 'SysInternals', 'WinDirStat', `
        'fzf', 'procexp', 'powershell-core', 'ussf', 'bat', `
        'ripgrep' | `
    ForEach-Object { 
        Write-Host "Installing $_..."
        choco install -y $_
    }


