
Write-Host 'Installing and configuring OSBasePackages...'
. "$PSScriptRoot\Utils.ps1"

'exiftool','geosetter' | ForEach-Object {
    Write-Host "Installing $_..."
    choco install -y $_
}

# dbxcli was delisted from the Chocolatey community repository (#13).
# Install via this bucket's Scoop manifest (DbxCli.json), which fetches
# the upstream GitHub release binary directly. See also #46.
'MarkMichaelis/DbxCli' | ForEach-Object {
    Write-Host "Installing $_..."
    scoop install $_
}

# Claude for Excel must be installed after Microsoft Office (which is a
# `depends` of this package) since it's an Office Web Add-in registered
# under Excel's WEF (Web Extension Framework). It's installed here -
# rather than as part of AIAgents - so the AIAgents bucket stays
# Office-independent for users who only want the AI clients/CLIs.
'ClaudeExcel' | ForEach-Object {
    Write-Host "Installing $_..."
    Install-BucketApp $_
}

'AIAgents' | ForEach-Object {
    Write-Host "Installing $_..."
    Install-BucketApp $_
}

$WingetPackages = @{
    'AmazonKindle'=([PSCustomObject]@{ WingetName='Amazon Kindle'; WinGetID='Amazon.Kindle'; })
    'Bitwarden'=([PSCustomObject]@{ WingetName='Bitwarden'; WinGetID='Bitwarden.Bitwarden'; })
    'BitwardenCLI'=([PSCustomObject]@{ WingetName='Bitwarden CLI'; WinGetID='Bitwarden.CLI'; })
    'calibre'=([PSCustomObject]@{ WingetName='calibre'; WinGetID='calibre.calibre'; })
#    'Comet'=([PSCustomObject]@{ WingetName='Comet (Perplexity)'; WinGetID='Perplexity.Comet'; })
    'SoX'=([PSCustomObject]@{ WingetName='SoX'; WinGetID='ChrisBagwell.SoX';  })
    'Dropbox'=([PSCustomObject]@{ WingetName='Dropbox'; WinGetID='Dropbox.Dropbox'; })
    # foxitreader's choco package times out downloading the upstream
    # installer in CI (#27). Foxit publishes a winget manifest, which is
    # also the preferred install engine per the README.
    'FoxitReader'=([PSCustomObject]@{ WingetName='Foxit PDF Reader'; WinGetID='Foxit.FoxitReader'; })
#    'PowerAutomate'=([PSCustomObject]@{ WingetName='Power Automate'; WinGetID='Microsoft.PowerAutomateDesktop'; })
    # Pushbullet: no machine-scope winget installer, no MS Store entry, no
    # scoop manifest. The choco `pushbullet` package (v1.0.0, 2017) wraps
    # the long-discontinued standalone desktop app. Left on CISkip until
    # an upstream alternative appears. Refs #8/#46.
    'Pushbullet'=([PSCustomObject]@{ WingetName='Pushbullet'; WinGetID='Pushbullet.Pushbullet'; })
    'Signal'=([PSCustomObject]@{ WingetName='Signal'; WinGetID='OpenWhisperSystems.Signal'; })
}

# Apps with no machine-scope winget installer and no Microsoft Store
# alternative — install via the scoop `extras` bucket instead. See #5
# (Claude), #6 (eSpeak NG), #7 (Notion), #10 (Spotify), #12 (Zoom).
'extras/claude','espeak-ng','extras/notion','extras/spotify','extras/zoom' | ForEach-Object {
    Write-Host "Installing $_..."
    scoop install -g $_
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
    # Snagit and Todoist publish only user-scope MSIX through winget's
    # default source; the Microsoft Store listing is the cleanest fully
    # automated path. Refs #9 (Snagit), #11 (Todoist).
    'Snagit'=([PSCustomObject]@{ WingetName='Snagit'; WinGetID='XPDNSF6TXN2R6Z'; })
    'Todoist'=([PSCustomObject]@{ WingetName='Todoist'; WinGetID='9MWF2DWS5Z9N'; })
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

