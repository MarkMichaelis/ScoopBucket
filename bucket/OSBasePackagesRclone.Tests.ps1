#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first regression for the OSBasePackages rclone entry (#459).

.DESCRIPTION
    rclone is a cloud-storage CLI (sync/copy/mount/serve against ~70 providers)
    and belongs with the other base CLI tooling in OSBasePackages.

    The data-driven cases in Bundles.Tests.ps1 already assert the generic
    invariants every package must satisfy. This focused test pins the
    rclone-specific contract so a regression -- dropping the package, retargeting
    the Id, or downgrading native completion to a hand-curated list -- fails here
    with a named diagnostic rather than being absorbed into a generic failure.

    Completion is 'native' because rclone ships a cobra-generated generator,
    verified against a real 1.75.1 install:
        PS> rclone completion powershell
        # powershell completion for rclone   -*- shell-script -*-
    Completion is a property of the binary, not the engine.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) {
        Import-Module $scoopBucketPsd1 -Force
    } else {
        Import-Module MarkMichaelis.ScoopBucket -Force
    }
    $script:rclone = Get-Package -BucketPath $PSScriptRoot -Name 'rclone'
}

Describe 'OSBasePackages: rclone' -Tag 'Light','Bundle' {

    It 'declares the rclone package exactly once' {
        @($script:rclone).Count | Should -Be 1
    }

    It 'is declared in the OSBasePackages bundle' {
        $script:rclone.Bundle | Should -Be 'OSBasePackages'
    }

    It 'installs from winget as Rclone.Rclone' {
        $script:rclone.Installer | Should -Be 'winget'
        $script:rclone.Id        | Should -Be 'Rclone.Rclone'
    }

    It 'declares rclone as the only CliCommand (matches the single shim winget Links creates)' {
        @($script:rclone.CliCommands) | Should -Be @('rclone')
    }

    It "uses native completion, not a hand-curated list" {
        $script:rclone.Completion           | Should -Be 'native'
        $script:rclone.NativeCompletionKind | Should -Be 'native'
        $script:rclone.HasNativeCommandScript | Should -BeTrue
    }

    It 'declares ExpectedCompletions covering real rclone subcommands' {
        $script:rclone.ExpectedCompletions | Should -Not -BeNullOrEmpty
        $script:rclone.ExpectedCompletions.ContainsKey('rclone') | Should -BeTrue
        $expected = @($script:rclone.ExpectedCompletions['rclone'])
        $expected.Count | Should -BeGreaterThan 0
        # Drawn from the real `rclone --help` command list, not invented.
        foreach ($cmd in 'config','copy','sync') {
            $expected | Should -Contain $cmd -Because "'$cmd' is a documented rclone subcommand"
        }
    }

    It 'declares no DependsOn (it is transitively closed and same-bundle-only, #450)' {
        @($script:rclone.DependsOn) | Should -BeNullOrEmpty
    }
}
