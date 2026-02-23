
Write-Host 'Installing and configuring OSBasePackages...'
. "$PSScriptRoot\Utils.ps1"

'foxitreader','exiftool','dbxcli','geosetter' | ForEach-Object { 
    Write-Host "Installing $_..."
    choco install -y $_
}

$WingetPackages = @{
    'AmazonKindle'=([PSCustomObject]@{ WingetName='Amazon Kindle'; WinGetID='Amazon.Kindle'; })
    'calibre'=([PSCustomObject]@{ WingetName='calibre'; WinGetID='calibre.calibre'; })
    'Claude'=([PSCustomObject]@{ WingetName='Claude'; WinGetID='Anthropic.Claude'; })
    'Comet'=([PSCustomObject]@{ WingetName='Comet (Perplexity)'; WinGetID='Perplexity.Comet'; })
    'Dropbox'=([PSCustomObject]@{ WingetName='Dropbox'; WinGetID='Dropbox.Dropbox'; })
    'Notion'=([PSCustomObject]@{ WingetName='Notion'; WinGetID='Notion.Notion'; })
    'PowerAutomate'=([PSCustomObject]@{ WingetName='Power Automate'; WinGetID='Microsoft.PowerAutomateDesktop'; })
    'Pushbullet'=([PSCustomObject]@{ WingetName='Pushbullet'; WinGetID='Pushbullet.Pushbullet'; })
    'Signal'=([PSCustomObject]@{ WingetName='Signal'; WinGetID='OpenWhisperSystems.Signal'; })
    'Snagit'=([PSCustomObject]@{ WingetName='Snagit'; WinGetID='TechSmith.Snagit.2024'; })
    'Spotify'=([PSCustomObject]@{ WingetName='Spotify'; WinGetID='Spotify.Spotify'; })
    'Todoist'=([PSCustomObject]@{ WingetName='Todoist'; WinGetID='Doist.Todoist'; })
    'Zoom'=([PSCustomObject]@{ WingetName='Zoom'; WinGetID='Zoom.Zoom.EXE'; })
}

$WingetPackages.Values | `
    ForEach-Object { 
        Write-Host "Installing $($_.WingetName)..."
        winget install --scope machine --id $_.WinGetID
    }

