#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for the Python entry in DeveloperBasePackages
    (issue #229: pscompletions -> native conversion, Phase 2).

.DESCRIPTION
    Locks in the contract that `python` ships a hand-curated native
    PowerShell argument completer instead of relying on the
    `pscompletions` catalog. Mirrors the pattern already in place for
    `devenv`, `code`, `copilot`, and `aspire` in the same bundle.

    These tests fail if the entry is reverted to `Completion = pscompletions`
    (no NativeCommandScript) -- providing the regression guard.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
    $script:pkgs = @(Get-Package -BucketPath $PSScriptRoot)
    $script:python = @($script:pkgs | Where-Object Name -EQ 'Python')
}

Describe 'DeveloperBasePackages: Python uses native completion (issue #229)' -Tag 'Light','Bundle','Completion' {

    It 'declares exactly one Python entry in DeveloperBasePackages' {
        $script:python.Count | Should -Be 1
        $script:python[0].Bundle | Should -Be 'DeveloperBasePackages'
    }

    It 'declares CliCommands=python' {
        @($script:python[0].CliCommands) | Should -Be @('python')
    }

    It "uses Completion='auto' (no longer pscompletions)" {
        $script:python[0].Completion | Should -Be 'auto'
    }

    It 'ships a NativeCommandScript' {
        $script:python[0].HasNativeCommandScript | Should -BeTrue
    }

    It 'declares non-empty ExpectedCompletions for python' {
        $script:python[0].ExpectedCompletions.ContainsKey('python') | Should -BeTrue
        @($script:python[0].ExpectedCompletions['python']).Count | Should -BeGreaterThan 0
        foreach ($expected in '--help','--version','-m') {
            $script:python[0].ExpectedCompletions['python'] | Should -Contain $expected
        }
    }

    It 'NativeCommandScript renders a Register-ArgumentCompleter -Native for python' {
        $rendered = $script:python[0].NativeCommandOutputs['python']
        $rendered | Should -Not -BeNullOrEmpty
        $rendered | Should -Match 'Register-ArgumentCompleter\s+-Native'
        $rendered | Should -Match '-CommandName\s+python'
    }

    It 'NativeCommandScript exposes the canonical CPython flags' {
        $rendered = $script:python[0].NativeCommandOutputs['python']
        foreach ($flag in "'-c'","'-m'","'-V'","'--version'","'-h'","'--help'") {
            $rendered | Should -BeLike "*$flag*"
        }
    }
}
