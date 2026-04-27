
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

# Aspire requires the .NET SDK (installed above as `dotnet`) and is normally
# paired with Visual Studio (installed above) and/or VS Code. Place this
# install last so the SDK and Visual Studio are present when the Aspire CLI
# registers its global dotnet tool and project templates.
'MarkMichaelis/Aspire' | ForEach-Object {
    Write-Host "Installing $_..."
    scoop install $_
}


