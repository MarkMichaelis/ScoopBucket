
Write-Host 'Installing and configuring OSBasePackages...'
. "$PSScriptRoot\Utils.ps1"

'nodejs' | ForEach-Object { 
    Write-Host "Installing $_..."
    choco install -y $_
}

#hub - GitHub CLI
'gh', 'dotnet', 'VisualStudio2026Enterprise' | ForEach-Object { 
    Write-Host "Installing $_..."
    scoop install -g $_
}

$WingetPackages = @{
    'VisualStudioCode'=([PSCustomObject]@{ WingetName='Visual Studio Code'; WinGetID='Microsoft.VisualStudioCode'; })
    'Cursor'=([PSCustomObject]@{ WingetName='Cursor'; WinGetID='Anysphere.Cursor'; })
    'CopilotCLI'=([PSCustomObject]@{ WingetName='Copilot CLI'; WinGetID='GitHub.Copilot'; })
    'AIShell'=([PSCustomObject]@{ WingetName='AI Shell'; WinGetID='Microsoft.AIShell'; })
    'Python'=([PSCustomObject]@{ WingetName='Python'; WinGetID='Python.Python.3.14'; })
    'Miniforge3'=([PSCustomObject]@{ WingetName='Miniforge3'; WinGetID='CondaForge.Miniforge3'; })
    'BeyondCompare'=([PSCustomObject]@{ WingetName='Beyond Compare'; WinGetID='ScooterSoftware.BeyondCompare.4'; })
}

$WingetPackages.Values | `
    ForEach-Object { 
        Write-Host "Installing $($_.WingetName)..."
        winget install --scope machine --id $_.WinGetID
    }


