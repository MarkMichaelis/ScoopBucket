#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for the Todoist + Todoist CLI co-location in
    ClientBasePackages, including the DependsOn regression guard that
    locks in "install Todoist, get the CLI too" (issue #208).
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
    $script:pkgs = @(Get-Package -BucketPath $PSScriptRoot)
}

Describe 'ClientBasePackages: Todoist CLI co-located with Todoist desktop' -Tag 'Light','Bundle' {

    It 'declares the existing Todoist desktop entry (regression guard)' {
        $desktop = @($script:pkgs | Where-Object Name -EQ 'Todoist')
        $desktop.Count        | Should -Be 1
        $desktop[0].Installer | Should -Be 'winget'
        $desktop[0].Id        | Should -Be '9MWF2DWS5Z9N'
        $desktop[0].Source    | Should -Be 'msstore'
        $desktop[0].Bundle    | Should -Be 'ClientBasePackages'
    }

    It 'declares a Todoist CLI package using sachaos/todoist via winget' {
        $cli = @($script:pkgs | Where-Object Name -EQ 'Todoist CLI')
        $cli.Count        | Should -Be 1
        $cli[0].Installer | Should -Be 'winget'
        $cli[0].Id        | Should -Be 'Sachaos.Todoist'
        $cli[0].Bundle    | Should -Be 'ClientBasePackages'
    }

    It 'declares CliCommands=todoist with native completion and expected subcommands' {
        $cli = @($script:pkgs | Where-Object Name -EQ 'Todoist CLI')[0]
        $cli.CliCommands              | Should -Be @('todoist')
        $cli.Completion               | Should -Be 'native'
        $cli.HasNativeCommandScript   | Should -BeTrue
        $cli.ExpectedCompletions.ContainsKey('todoist') | Should -BeTrue
        foreach ($expected in 'add','list','show','completion','--help') {
            $cli.ExpectedCompletions['todoist'] | Should -Contain $expected
        }
    }

    It 'passes --silent and --disable-interactivity to winget' {
        $cli = @($script:pkgs | Where-Object Name -EQ 'Todoist CLI')[0]
        $cli.WingetExtraArgs | Should -Contain '--silent'
        $cli.WingetExtraArgs | Should -Contain '--disable-interactivity'
    }

    It 'DependsOn the desktop Todoist (auto-install-with-desktop regression guard)' {
        $cli = @($script:pkgs | Where-Object Name -EQ 'Todoist CLI')[0]
        @($cli.DependsOn)       | Should -Be @('Todoist')
    }
}
