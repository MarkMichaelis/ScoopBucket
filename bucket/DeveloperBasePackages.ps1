
Write-Host 'Installing and configuring OSBasePackages...'
. "$PSScriptRoot\Utils.ps1"

'nodejs' | ForEach-Object { 
    Write-Host "Installing $_..."
    choco install -y $_
}

#hub - GitHub CLI
'gh', 'dotnet', 'VisualStudio2022Enterprise' | ForEach-Object { 
    Write-Host "Installing $_..."
    scoop install -g $_
}


