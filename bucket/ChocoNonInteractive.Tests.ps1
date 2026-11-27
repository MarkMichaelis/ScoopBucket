#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Every choco install/upgrade the bucket runs is non-interactive (#563).

.DESCRIPTION
    Without -y, `choco install` asks "Do you want to run the script?" and
    waits for an answer an unattended install never gives. #563 made
    TotalCommander a default package and put PowerShellWindows,
    PowerShellCorePreview and Git settings for Visual Studio in the picker,
    and each of them ran choco without -y. This scans manifests' installer
    scripts and the code lines of bucket scripts.
#>

BeforeDiscovery {
    $bucket = $PSScriptRoot
    $chocoCall = '\bchoco(\.exe)?\s+(install|upgrade)\b'
    $cases = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($m in Get-ChildItem -LiteralPath $bucket -Filter '*.json' -File -Recurse | Where-Object Extension -eq '.json') {
        $json = Get-Content -Raw -LiteralPath $m.FullName | ConvertFrom-Json -ErrorAction SilentlyContinue
        foreach ($line in @($json.installer.script) + @($json.pre_install) + @($json.post_install)) {
            if ($line -match $chocoCall) { $cases.Add(@{ Where = $m.Name; Line = [string]$line }) }
        }
    }
    foreach ($s in Get-ChildItem -LiteralPath $bucket -Filter '*.ps1' -File -Recurse | Where-Object Name -notmatch '\.Tests\.ps1$') {
        # Commands only: a comment or a string that mentions choco is not a call.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$null, [ref]$null)
        foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^choco(\.exe)?$' }, $true)) {
            if ($cmd.Extent.Text -match $chocoCall) { $cases.Add(@{ Where = $s.Name; Line = $cmd.Extent.Text }) }
        }
    }
    $script:Cases = $cases.ToArray()
}

Describe 'choco runs non-interactively' -Tag 'Light', 'Bucket' {
    It 'finds choco calls to check' -ForEach @(@{ Count = $script:Cases.Count }) {
        $Count | Should -BeGreaterThan 0
    }

    It '<Where>: <Line>' -ForEach $script:Cases {
        $Line | Should -Match '(\s-y\b|\s--yes\b|\s--confirm\b)' -Because 'choco waits for a confirmation an unattended install never gives'
    }
}
