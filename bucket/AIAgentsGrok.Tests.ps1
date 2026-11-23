#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first test for the AIAgents Grok CLI entry (#507).

.DESCRIPTION
    Grok Build is xAI's coding-agent CLI (command `grok`). It installs from
    winget (README rule 1) as xAI.GrokBuild, published by xAI Corp.: a
    portable install whose manifest declares the command alias `grok`, so
    --scope machine links it into C:\Program Files\WinGet\Links, the same
    shape as ripgrep and rclone. It sits with the other agent CLIs in the
    AIAgents bundle.

    Completion is 'native' because grok ships a clap-generated generator,
    verified against the real 1.0.70 binary:
        PS> grok completions powershell
        Register-ArgumentCompleter -Native -CommandName 'grok' -ScriptBlock {
    Completion is a property of the binary, not the engine.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) {
        Import-Module $scoopBucketPsd1 -Force
    } else {
        Import-Module MarkMichaelis.ScoopBucket -Force
    }
    $script:grok = Get-Package -BucketPath $PSScriptRoot -Name 'Grok CLI'
}

Describe 'AIAgents: Grok CLI' -Tag 'Light','Bundle' {

    It 'declares the Grok CLI package exactly once' {
        @($script:grok | Where-Object { $_ }).Count | Should -Be 1
    }

    It 'is declared in the AIAgents bundle, with the other agent CLIs' {
        $script:grok.Bundle | Should -Be 'AIAgents'
    }

    It 'installs from winget as xAI.GrokBuild, the official xAI package' {
        $script:grok.Installer | Should -Be 'winget'
        $script:grok.Id        | Should -Be 'xAI.GrokBuild'
    }

    It 'installs machine-scope so the grok alias lands in the machine WinGet Links directory' {
        "$($script:grok.Scope)" | Should -Not -Be 'user'
    }

    It 'declares grok as the only CliCommand (the single alias the winget manifest declares)' {
        @($script:grok.CliCommands) | Should -Be @('grok')
    }

    It 'uses native completion, not a hand-curated list' {
        $script:grok.Completion             | Should -Be 'native'
        $script:grok.NativeCompletionKind   | Should -Be 'native'
        $script:grok.HasNativeCommandScript | Should -BeTrue
    }

    It 'declares ExpectedCompletions covering real grok subcommands' {
        $script:grok.ExpectedCompletions | Should -Not -BeNullOrEmpty
        $script:grok.ExpectedCompletions.ContainsKey('grok') | Should -BeTrue
        $expected = @($script:grok.ExpectedCompletions['grok'])
        # Drawn from the real `grok completions powershell` output, not invented.
        foreach ($cmd in 'login','mcp','models','sessions') {
            $expected | Should -Contain $cmd -Because "'$cmd' is a grok subcommand the 1.0.70 completer emits"
        }
    }

    It 'declares no DependsOn (a native binary; winget pulls its VCRedist dependency itself)' {
        @($script:grok.DependsOn) | Should -BeNullOrEmpty
    }
}
