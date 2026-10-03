#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for the Android platform-tools (adb/fastboot) entry
    in DeveloperBasePackages (issue #293).

.DESCRIPTION
    Locks in the contract that the bucket ships Android platform-tools with
    curated PowerShell argument completers for both `adb` and `fastboot`.
    Mirrors the pattern already in place for `python`, `devenv`, `code`,
    `copilot`, and `aspire` in the same bundle.

    The engine is winget as of #465. The entry was originally `scoop`
    (`main/adb`) with no recorded justification -- the same defect #462/#463
    corrected for rclone. winget's Google.PlatformTools is the identical
    artifact at the identical version:

        PS> winget show --id Google.PlatformTools --exact --scope machine
        Version: 37.0.1
        Installer Type: portable (zip)
        Installer Url: https://dl.google.com/android/repository/platform-tools_r37.0.1-win.zip

    and its manifest declares a PortableCommandAlias for BOTH binaries
    (`platform-tools/adb.exe` -> adb, `platform-tools/fastboot.exe` -> fastboot)
    plus `ArchiveBinariesDependOnPath: true`, so both CliCommands survive the
    move.

    These tests fail if the entry is removed, retargeted to another engine, or
    reverted to a no-completion shape -- providing the regression guard.
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

    It 'installs via winget from Google.PlatformTools (#465)' {
        # README rule 1: winget first for CLIs. winget carries platform-tools at
        # the same version and from the same zip scoop's main/adb consumes, and
        # aliases both adb and fastboot, so no fall-through condition applies.
        $script:adb[0].Installer | Should -Be 'winget'
        $script:adb[0].Id | Should -Be 'Google.PlatformTools'
    }

    It 'installs machine-scope (no Scope override -- winget resolves --scope machine)' {
        "$($script:adb[0].Scope)" | Should -Not -Be 'user'
    }

    It 'records the engine rationale in Notes' {
        $script:adb[0].Notes | Should -Not -BeNullOrEmpty
        $script:adb[0].Notes | Should -Match 'winget'
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
