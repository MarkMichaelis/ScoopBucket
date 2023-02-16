
Write-Host 'Installing and configuring OSBasePackages...'
. "$PSScriptRoot\Utils.ps1"

'foxitreader','exiftool','dbxcli' | ForEach-Object { 
    Write-Host "Installing $_..."
    choco install -y $_
}

'' | ForEach-Object { 
    Write-Host "Installing $_..."
    choco install -y $_
}


