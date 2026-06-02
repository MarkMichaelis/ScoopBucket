#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for the Android platform-tools (adb/fastboot) entry
    in DeveloperBasePackages (issue #293).

.DESCRIPTION
    Locks in the contract that the bucket ships Android platform-tools via
    scoop (main/adb) with curated PowerShell argument completers for both
    `adb` and `fastboot`. Mirrors the pattern already in place for `python`,
    `devenv`, `code`, `copilot`, and `aspire` in the same bundle.

    These tests fail if the entry is removed or reverted to a non-scoop /
    no-completion shape -- providing the regression guard.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
    $script:pkgs = @(Get-Package -BucketPath $PSScriptRoot)
    $script:adb = @($script:pkgs | Where-Object { $_.CliCommands -contains 'adb' })
}

Describe 'DeveloperBasePackages: Android platform-tools (issue #293)' -Tag 'Light','Bundle','Completion' {

    It 'declares exactly one Android platform-tools entry in DeveloperBasePackages' {
        $script:adb.Count | Should -Be 1
        $script:adb[0].Bundle | Should -Be 'DeveloperBasePackages'
    }

    It 'installs via scoop from main/adb' {
        $script:adb[0].Installer | Should -Be 'scoop'
        $script:adb[0].Id | Should -Be 'main/adb'
    }

    It 'declares CliCommands adb and fastboot' {
        @($script:adb[0].CliCommands) | Should -Contain 'adb'
        @($script:adb[0].CliCommands) | Should -Contain 'fastboot'
    }

    It "uses Completion='auto'" {
        $script:adb[0].Completion | Should -Be 'auto'
    }

    It 'is curated (no NativeCompletionKind -- adb has no native PS completion engine)' {
        # adb/fastboot ship no `completions powershell` subcommand, so the
        # completer is hand-curated, not sourced live from the tool (#289).
        "$($script:adb[0].NativeCompletionKind)" | Should -Be ''
    }

    It 'ships a NativeCommandScript' {
        $script:adb[0].HasNativeCommandScript | Should -BeTrue
    }

    It 'declares non-empty ExpectedCompletions for adb and fastboot' {
        $script:adb[0].ExpectedCompletions.ContainsKey('adb') | Should -BeTrue
        $script:adb[0].ExpectedCompletions.ContainsKey('fastboot') | Should -BeTrue
        @($script:adb[0].ExpectedCompletions['adb']).Count | Should -BeGreaterThan 0
        @($script:adb[0].ExpectedCompletions['fastboot']).Count | Should -BeGreaterThan 0
        foreach ($expected in 'devices','install','shell') {
            $script:adb[0].ExpectedCompletions['adb'] | Should -Contain $expected
        }
        foreach ($expected in 'devices','flash','reboot') {
            $script:adb[0].ExpectedCompletions['fastboot'] | Should -Contain $expected
        }
    }

    It 'NativeCommandScript renders Register-ArgumentCompleter -Native for adb and fastboot' {
        foreach ($cli in 'adb','fastboot') {
            $rendered = $script:adb[0].NativeCommandOutputs[$cli]
            $rendered | Should -Not -BeNullOrEmpty
            $rendered | Should -Match 'Register-ArgumentCompleter\s+-Native'
            $rendered | Should -Match "-CommandName\s+$cli"
        }
    }

    It 'NativeCommandScript exposes canonical adb subcommands' {
        $rendered = $script:adb[0].NativeCommandOutputs['adb']
        foreach ($sub in "'devices'","'install'","'shell'","'logcat'") {
            $rendered | Should -BeLike "*$sub*"
        }
    }
}
