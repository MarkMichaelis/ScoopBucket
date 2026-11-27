#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    The picker shows the owner's outline of the three base bundles (#563).

.DESCRIPTION
    Built from this bucket, not a fixture: the tree Install-Package -DryRun
    opens, with its default selection. Checks the shape and defaults the
    owner's outline and decisions in #563 settled -- not every row.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1') -Force
    $script:M = Get-Module MarkMichaelis.ScoopBucket
    $script:State = & $script:M {
        param($bucket)
        New-PickerState -Catalog (Get-PackageCatalog -BucketPath $bucket)
    } $PSScriptRoot
    $script:Roots = $script:State.Catalog.Roots

    function script:Get-Child([object]$Node, [string]$Name) {
        $children = if ($Node.Kind -eq 'Group') { $Node.Children } else { & $script:M { param($n) Get-PickerSubItems -Node $n } $Node }
        @($children | Where-Object Name -eq $Name) | Select-Object -First 1
    }
    function script:Get-Root([string]$Name) { $script:Roots | Where-Object Name -eq $Name }
    function script:Test-Checked([object]$Node) { $script:State.Selected.Contains($Node.Identity) }
    function script:Get-AllNames {
        $names = [System.Collections.Generic.List[string]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        $walk = {
            param($n)
            if (-not $seen.Add("$($n.Key)|$($n.Role)")) { return }
            $names.Add($n.Name)
            $kids = if ($n.Kind -eq 'Group') { $n.Children } else { & $script:M { param($x) Get-PickerSubItems -Node $x } $n }
            foreach ($c in @($kids)) { if ($c) { & $walk $c } }
        }
        foreach ($r in $script:Roots) { & $walk $r }
        $names
    }
}

Describe 'The picker shows the owner''s outline (#563)' -Tag 'Light', 'Picker' {
    Context 'Developer Base' {
        BeforeAll {
            $script:Dev = Get-Root 'Developer Base Packages'
            $script:GitTools = Get-Child $script:Dev 'Git Tools'
        }

        It 'starts with the Git Tools group, which is shown only there' {
            $script:Dev.Children[0].Name | Should -Be 'Git Tools'
            $script:GitTools.Kind | Should -Be 'Group'
            $script:Roots.Name | Should -Not -Contain 'Git Tools'
        }

        It 'lists Git Tools'' items in the outline''s order' {
            $script:GitTools.Children.Name | Should -Be @('Git', 'posh-git', 'Commit identity', 'GitHub CLI', 'GitKraken', 'Git Extensions', 'Lazygit')
        }

        It 'shows Git, required, with its set-up items under it' {
            $git = Get-Child $script:GitTools 'Git'
            $git.Package.Required | Should -BeTrue
            @(& $script:M { param($n) Get-PickerSubItems -Node $n } $git).Name |
                Should -Be @('ssh-agent', 'Global Git settings', 'Debug diff tools', 'Share Git settings from Data', 'Link ~\.ssh to Data')
        }

        It 'turns on every Git set-up item except linking ~\.ssh to Data' {
            $git = Get-Child $script:GitTools 'Git'
            foreach ($n in 'ssh-agent', 'Global Git settings', 'Debug diff tools', 'Share Git settings from Data') {
                Test-Checked (Get-Child $git $n) | Should -BeTrue -Because "$n is on in the outline"
            }
            Test-Checked (Get-Child $git 'Link ~\.ssh to Data') | Should -BeFalse
        }

        It 'shows each Git client''s companion under it' {
            (Get-Child (Get-Child $script:GitTools 'GitHub CLI') 'GitHub CLI settings').Role | Should -Be 'Companion'
            (Get-Child (Get-Child $script:GitTools 'GitKraken') 'GitKraken CLI').Role | Should -Be 'Companion'
        }

        It 'lists Node.js as an item of its own' {
            $script:Dev.Children.Name | Should -Contain 'Node.js'
        }

        It 'leaves Visual Studio and Android Platform Tools off' {
            Test-Checked (Get-Child $script:Dev 'Visual Studio') | Should -BeFalse
            Test-Checked (Get-Child $script:Dev 'Android Platform Tools') | Should -BeFalse
        }

        It 'leaves Visual Studio''s Git settings off while Visual Studio is off, and turns them on with it' {
            $vs = Get-Child $script:Dev 'Visual Studio'
            $settings = Get-Child $vs 'Git settings for Visual Studio'
            $settings.Role | Should -Be 'Companion'
            Test-Checked $settings | Should -BeFalse
            & $script:M { param($s, $n) Switch-PickerNode -State $s -Node $n } $script:State $vs
            try {
                Test-Checked $settings | Should -BeTrue
            } finally {
                & $script:M { param($s, $n) Switch-PickerNode -State $s -Node $n } $script:State $vs
            }
        }
    }

    Context 'OS Base' {
        BeforeAll { $script:OS = Get-Root 'OS Base Packages' }

        It 'shows the same Git and VS Code as Developer Base: one checkbox each' {
            $dev = Get-Root 'Developer Base Packages'
            (Get-Child $script:OS 'Git').Identity | Should -Be (Get-Child (Get-Child $dev 'Git Tools') 'Git').Identity
            (Get-Child $script:OS 'Visual Studio Code').Identity | Should -Be (Get-Child $dev 'Visual Studio Code').Identity
            @(& $script:M { param($n) Get-PickerSubItems -Node $n } (Get-Child $script:OS 'Git')).Count | Should -Be 5
        }

        It 'groups PowerShell after Windows Terminal: PowerShellCore on, the other two off' {
            $script:OS.Children[1].Name | Should -Be 'PowerShell'
            $ps = $script:OS.Children[1]
            $ps.Children.Name | Should -Be @('PowerShellCore', 'PowerShellCorePreview', 'Windows PowerShell 5.1 modules')
            Test-Checked $ps.Children[0] | Should -BeTrue
            Test-Checked $ps.Children[1] | Should -BeFalse
            Test-Checked $ps.Children[2] | Should -BeFalse
        }

        It 'turns on <_>' -ForEach @('TotalCommander', 'McAfeeUninstall') {
            Test-Checked (Get-Child $script:OS $_) | Should -BeTrue
        }
    }

    Context 'Client Base' {
        BeforeAll { $script:Client = Get-Root 'Client Base Packages' }

        It 'turns on <_>' -ForEach @('AdobeLightroomClassic', 'Epubor', 'SmugMug') {
            Test-Checked (Get-Child $script:Client $_) | Should -BeTrue
        }

        It 'leaves <_> off' -ForEach @('Handy', 'eSpeak NG') {
            Test-Checked (Get-Child $script:Client $_) | Should -BeFalse
        }

        It 'shows Node.js inside AI Agents only under the agents that need it' {
            (Get-Child $script:Client 'AI Agents').Children.Name | Should -Not -Contain 'Node.js'
        }
    }

    It 'no longer offers <_>' -ForEach @('Overdrive', 'WindowsPowerShell', 'WSL-Ubuntu-1804', 'WSL-Ubuntu-2004', 'GitConfigure') {
        Get-AllNames | Should -Not -Contain $_
    }

    It 'offers one WSL Ubuntu item, off' {
        $names = Get-AllNames
        $names | Should -Contain 'WSLUbuntu'
    }
}
