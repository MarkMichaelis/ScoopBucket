
Write-Host 'Installing and configuring OSBasePackages...'
. "$PSScriptRoot\Utils.ps1"

'foxitreader','exiftool','dbxcli' | ForEach-Object { 
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


