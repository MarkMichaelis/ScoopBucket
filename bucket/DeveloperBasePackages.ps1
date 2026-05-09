
Write-Host 'Installing and configuring OSBasePackages...'
. "$PSScriptRoot\Utils.ps1"

'nodejs' | ForEach-Object { 
    Write-Host "Installing $_..."
    choco install -y $_
}

#hub - GitHub CLI
# BeyondCompare: winget only ships a user-scope MSIX (`ScooterSoftware.BeyondCompare.4`)
# which fails machine-scope install in CI; the scoop `extras/beyondcompare`
# manifest installs cleanly. Refs #14/#46.
'dotnet', 'VisualStudio2026Enterprise', 'extras/beyondcompare' | ForEach-Object {
    Write-Host "Installing $_..."
    scoop install -g $_
}

$WingetPackages = @{
    'VisualStudioCode'=([PSCustomObject]@{ WingetName='Visual Studio Code'; WinGetID='Microsoft.VisualStudioCode'; })
#    'Cursor'=([PSCustomObject]@{ WingetName='Cursor'; WinGetID='Anysphere.Cursor'; })
    'CopilotCLI'=([PSCustomObject]@{ WingetName='Copilot CLI'; WinGetID='GitHub.Copilot'; })
#    'AIShell'=([PSCustomObject]@{ WingetName='AI Shell'; WinGetID='Microsoft.AIShell'; })
    'Python'=([PSCustomObject]@{ WingetName='Python'; WinGetID='Python.Python.3.14'; })
#    'Miniforge3'=([PSCustomObject]@{ WingetName='Miniforge3'; WinGetID='CondaForge.Miniforge3'; })
}

$WingetPackages.Values | `
    ForEach-Object { 
        Write-Host "Installing $($_.WingetName)..."
        winget install --scope machine --id $_.WinGetID
    }

# Aspire requires the .NET SDK (installed above as `dotnet`) and is normally
# paired with Visual Studio (installed above) and/or VS Code. Place this
# install last so the SDK and Visual Studio are present when the Aspire CLI
# registers its global dotnet tool and project templates.
'MarkMichaelis/Aspire' | ForEach-Object {
    Write-Host "Installing $_..."
    scoop install $_
}


