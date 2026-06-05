#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for the Todoist desktop entry in ClientBasePackages.

    The sachaos/todoist CLI companion (winget 'Sachaos.Todoist') was removed
    in #326 because the package was delisted from winget upstream -- confirmed
    on a clean CI runner in #325 (winget search/show/install all return
    -1978335212 "No package found"). The guards below lock in that removal:
    re-adding the dead CLI entry or its companion link fails them.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
    $script:pkgs = @(Get-Package -BucketPath $PSScriptRoot)
}

Describe 'ClientBasePackages: Todoist desktop entry' -Tag 'Light','Bundle' {

    It 'declares the existing Todoist desktop entry (regression guard)' {
        $desktop = @($script:pkgs | Where-Object Name -EQ 'Todoist')
        $desktop.Count        | Should -Be 1
        $desktop[0].Installer | Should -Be 'winget'
        $desktop[0].Id        | Should -Be '9MWF2DWS5Z9N'
        $desktop[0].Source    | Should -Be 'msstore'
        $desktop[0].Bundle    | Should -Be 'ClientBasePackages'
    }

    It 'no longer declares a Todoist CLI package (Sachaos.Todoist delisted from winget, #326)' {
        @($script:pkgs | Where-Object Name -EQ 'Todoist CLI').Count | Should -Be 0
        @($script:pkgs | Where-Object Id -EQ 'Sachaos.Todoist').Count | Should -Be 0
    }

    It 'Todoist desktop no longer lists a Todoist CLI companion (#326)' {
        $desktop = @($script:pkgs | Where-Object Name -EQ 'Todoist')[0]
        @($desktop.Companions) | Should -Not -Contain 'Todoist CLI'
    }

    It 'Bitwarden desktop declares Companions=@(Bitwarden CLI) (auto-install CLI with app)' {
        $desktop = @($script:pkgs | Where-Object Name -EQ 'Bitwarden')[0]
        @($desktop.Companions) | Should -Contain 'Bitwarden CLI'
    }
}
