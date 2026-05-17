# WindowsTerminalSkill - Control terminal tab title/color from child processes

$script:Colors = @{
    red = "E74C3C"; green = "2ECC71"; blue = "3498DB"; purple = "9B59B6"
    orange = "E67E22"; yellow = "F1C40F"; pink = "E91E63"; cyan = "00BCD4"
    bug = "E74C3C"; feature = "2ECC71"; research = "3498DB"; refactor = "9B59B6"
    devops = "E67E22"; test = "F1C40F"
}

function Set-TerminalDirect {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Color = "6C3BAA"
    )
    $Color = $Color -replace '^#', ''
    if ($script:Colors.ContainsKey($Color.ToLower())) {
        $Color = $script:Colors[$Color.ToLower()]
    }
    $r = $Color.Substring(0,2); $g = $Color.Substring(2,2); $b = $Color.Substring(4,2)
    $Host.UI.RawUI.WindowTitle = $Title
    Write-Host ([char]27 + "]4;264;rgb:$r/$g/$b" + [char]7) -NoNewline
}

function Set-Tab {
    param([Parameter(Mandatory)][string]$TitleAndColor)
    if ($TitleAndColor -match '^(.+)\|(\w+)$') {
        Set-TerminalDirect -Title $Matches[1] -Color $Matches[2]
    } else {
        Set-TerminalDirect -Title $TitleAndColor
    }
}

function tab {
    param(
        [Parameter(Position=0)][string]$Title,
        [Parameter(Position=1)][string]$Color = "purple"
    )
    if ($Title) { 
        Set-TerminalDirect -Title $Title -Color $Color
        Write-Host ""  # newline after the escape sequence
        Write-Host "Tab: $Title" -ForegroundColor DarkGray
    }
}

function Start-TerminalListener { }

Export-ModuleMember -Function Set-TerminalDirect, Set-Tab, Start-TerminalListener, tab
