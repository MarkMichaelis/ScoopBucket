#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Regression tests for issue #228: the `dotnet` entry in
    DeveloperBasePackages must source tab completion from the native
    `dotnet complete` API via Completion='auto' + NativeCommandScript,
    NOT from the third-party PSCompletions catalog.

.DESCRIPTION
    Asserts the migration away from Completion='pscompletions' for
    `dotnet`. These tests must fail if the entry is reverted to
    Completion='pscompletions' or loses its NativeCommandScript.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
    $script:dotnet = @(Get-Package -BucketPath $PSScriptRoot) |
        Where-Object { $_.Bundle -eq 'DeveloperBasePackages' -and $_.Name -eq 'dotnet' } |
        Select-Object -First 1
}

Describe 'DeveloperBasePackages dotnet native completion (issue #228)' -Tag 'Light','Bundle','Completion' {

    It 'declares the dotnet package' {
        $script:dotnet | Should -Not -BeNullOrEmpty
    }

    It "uses Completion='auto' (not 'pscompletions')" {
        $script:dotnet.Completion | Should -Be 'auto'
    }

    It 'ships a NativeCommandScript' {
        $script:dotnet.HasNativeCommandScript | Should -BeTrue
    }

    It 'NativeCommandScript invokes the official `dotnet complete` API' {
        $text = [string]$script:dotnet.NativeCommandOutputs['dotnet']
        $text | Should -Match 'Register-ArgumentCompleter\b[\s\S]*-CommandName\s+dotnet'
        $text | Should -Match 'dotnet\s+complete\b'
    }

    It 'declares an expanded ExpectedCompletions subset for tab-completion validation' {
        $expected = @($script:dotnet.ExpectedCompletions.dotnet)
        foreach ($cmd in 'add','build','clean','pack','publish','restore','run','test') {
            $expected | Should -Contain $cmd
        }
    }
}
