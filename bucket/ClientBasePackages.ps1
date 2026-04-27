
Write-Host 'Installing and configuring OSBasePackages...'
. "$PSScriptRoot\Utils.ps1"

'foxitreader','exiftool','dbxcli' | ForEach-Object { 
    Write-Host "Installing $_..."
    choco install -y $_
}

'MarkMichaelis/AIAgents' | ForEach-Object {
    Write-Host "Installing $_..."
    scoop install $_
}


