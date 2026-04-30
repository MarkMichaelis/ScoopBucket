
Write-Host 'Installing and configuring OSBasePackages...'
. "$PSScriptRoot\Utils.ps1"

'foxitreader','exiftool','dbxcli','geosetter' | ForEach-Object { 
    Write-Host "Installing $_..."
    choco install -y $_
}

# Claude for Excel must be installed after Microsoft Office (which is a
# `depends` of this package) since it's an Office Web Add-in registered
# under Excel's WEF (Web Extension Framework). It's installed here -
# rather than as part of AIAgents - so the AIAgents bucket stays
# Office-independent for users who only want the AI clients/CLIs.
'MarkMichaelis/ClaudeExcel' | ForEach-Object {
    Write-Host "Installing $_..."
    scoop install $_
}

'MarkMichaelis/AIAgents' | ForEach-Object {
    Write-Host "Installing $_..."
    scoop install $_
}

$WingetPackages = @{
    'AmazonKindle'=([PSCustomObject]@{ WingetName='Amazon Kindle'; WinGetID='Amazon.Kindle'; })
    'calibre'=([PSCustomObject]@{ WingetName='calibre'; WinGetID='calibre.calibre'; })
    'Claude'=([PSCustomObject]@{ WingetName='Claude'; WinGetID='Anthropic.Claude'; })
#    'Comet'=([PSCustomObject]@{ WingetName='Comet (Perplexity)'; WinGetID='Perplexity.Comet'; })
    'SoX'=([PSCustomObject]@{ WingetName='SoX'; WinGetID='ChrisBagwell.SoX';  })
    'eSpeak-NG'=([PSCustomObject]@{ WingetName='eSpeak NG'; WinGetID='eSpeak-NG.eSpeak-NG';  })
    'Dropbox'=([PSCustomObject]@{ WingetName='Dropbox'; WinGetID='Dropbox.Dropbox'; })
    'Notion'=([PSCustomObject]@{ WingetName='Notion'; WinGetID='Notion.Notion'; })
#    'PowerAutomate'=([PSCustomObject]@{ WingetName='Power Automate'; WinGetID='Microsoft.PowerAutomateDesktop'; })
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

# Microsoft Store apps (installed via winget --source msstore)
$MicrosoftStorePackages = @{
    'ChatGPT'=([PSCustomObject]@{ WingetName='ChatGPT'; WinGetID='9NT1R1C2HH7J'; })
    'VPNUnlimited'=([PSCustomObject]@{ WingetName='VPN Unlimited'; WinGetID='9NRQBLR605RG'; })
    'Grammarly'=([PSCustomObject]@{ WingetName='Grammarly'; WinGetID='XPDDXX9QW8N9D7'; })
    'WhatsApp'=([PSCustomObject]@{ WingetName='WhatsApp'; WinGetID='9NKSQGP7F2NH'; })
}

$MicrosoftStorePackages.Values | `
    ForEach-Object { 
        Write-Host "Installing $($_.WingetName)..."
        winget install --source msstore --id $_.WinGetID --accept-package-agreements --accept-source-agreements
    }

# Readwise Reader (sideloaded MSIX, not available in winget or Microsoft Store)
Write-Host "Installing Readwise Reader..."
Invoke-WebRequest -Uri 'https://readwise.io/read/download_latest/desktop/windows' -OutFile "$env:TEMP\ReadwiseReader.msix"
Add-AppxPackage -Path "$env:TEMP\ReadwiseReader.msix"
Remove-Item "$env:TEMP\ReadwiseReader.msix" -ErrorAction Ignore

