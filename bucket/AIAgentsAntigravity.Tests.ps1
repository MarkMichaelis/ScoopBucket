#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for Google's Antigravity agent in the AIAgents bundle,
    and the retirement of Gemini CLI that it replaces (#535).

.DESCRIPTION
    Google stopped serving Gemini CLI to individual accounts on 2026-06-18 and
    moved it to Antigravity CLI. AIAgents therefore installs:

      * Antigravity CLI -- winget Google.AntigravityCLI (publisher Google), a
        portable install whose manifest declares the command alias `agy` and
        no Scope, so --scope machine links agy into C:\Program Files\WinGet\Links
        (the same shape as grok).
      * Antigravity      -- winget Google.Antigravity, the Antigravity 2.0
        desktop agent app. Its manifest declares a nullsoft installer with
        Scope: user only, so the package must say Scope='user' or winget walks
        back to a stale machine-applicable version (#433).

    Gemini CLI (choco gemini-cli behind the MarkMichaelis/GeminiCli wrapper) is
    no longer declared, and the Gemini desktop entry's companion moves to
    Antigravity CLI.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) {
        Import-Module $scoopBucketPsd1 -Force
    } else {
        Import-Module MarkMichaelis.ScoopBucket -Force
    }
    $script:allPkgs = @(Get-Package -BucketPath $PSScriptRoot)
    $script:cli     = @($script:allPkgs | Where-Object Name -EQ 'Antigravity CLI')
    $script:app     = @($script:allPkgs | Where-Object Name -EQ 'Antigravity')
}

Describe 'AIAgents: Antigravity CLI' -Tag 'Light','Bundle' {

    It 'is declared exactly once, in the AIAgents bundle' {
        $script:cli.Count     | Should -Be 1
        $script:cli[0].Bundle | Should -Be 'AIAgents'
    }

    It 'installs from winget as Google.AntigravityCLI' {
        $script:cli[0].Installer | Should -Be 'winget'
        $script:cli[0].Id        | Should -Be 'Google.AntigravityCLI'
    }

    It 'installs machine-scope so the agy alias lands in the machine WinGet Links directory' {
        "$($script:cli[0].Scope)" | Should -Not -Be 'user'
    }

    It 'declares agy as its only CliCommand (the single alias the winget manifest declares)' {
        @($script:cli[0].CliCommands) | Should -Be @('agy')
    }

    It 'registers tab completion for agy' {
        $script:cli[0].Completion             | Should -Not -BeNullOrEmpty
        $script:cli[0].HasNativeCommandScript | Should -BeTrue
        $script:cli[0].ExpectedCompletions.ContainsKey('agy') | Should -BeTrue
    }
}

Describe 'AIAgents: Antigravity desktop app' -Tag 'Light','Bundle' {

    It 'is declared exactly once, in the AIAgents bundle' {
        $script:app.Count     | Should -Be 1
        $script:app[0].Bundle | Should -Be 'AIAgents'
    }

    It 'installs from winget as Google.Antigravity, user scope (the only scope the manifest offers)' {
        $script:app[0].Installer | Should -Be 'winget'
        $script:app[0].Id        | Should -Be 'Google.Antigravity'
        $script:app[0].Scope     | Should -Be 'user'
    }

    It 'is not the Antigravity IDE' {
        @($script:allPkgs | Where-Object Id -EQ 'Google.AntigravityIDE') | Should -BeNullOrEmpty
    }
}

Describe 'AIAgents: Gemini CLI is retired in favor of Antigravity CLI' -Tag 'Light','Bundle' {

    It 'no bundle declares Gemini CLI' {
        @($script:allPkgs | Where-Object { $_.Name -eq 'Gemini CLI' -or $_.Id -eq 'MarkMichaelis/GeminiCli' }) |
            Should -BeNullOrEmpty
    }

    It 'the GeminiCli manifest is gone' {
        Join-Path $PSScriptRoot 'ai\GeminiCli.json' | Should -Not -Exist
    }

    It 'the Gemini desktop entry pairs with Antigravity CLI' {
        $gemini = @($script:allPkgs | Where-Object { $_.Bundle -eq 'AIAgents' -and $_.Name -eq 'Gemini' })
        $gemini.Count | Should -Be 1
        @($gemini[0].Companions) | Should -Be @('Antigravity CLI')
    }
}

Describe 'AIAgents MCP: Antigravity replaces Gemini CLI as a JSON agent' -Tag 'Light','Bundle' {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'AIAgents.Mcp.ps1')
        $script:jsonAgents = @(Get-AIAgentsMcpJsonAgent)
    }

    It 'wires MCP servers into Antigravity''s shared mcp_config.json' {
        # Antigravity CLI, the 2.0 app and the IDE share this global file
        # (antigravity.google/docs/mcp).
        ($script:jsonAgents | Where-Object Label -EQ 'Antigravity').Path |
            Should -Be (Join-Path $env:USERPROFILE '.gemini\config\mcp_config.json')
    }

    It 'no longer writes Gemini CLI''s settings.json' {
        @($script:jsonAgents | Where-Object { $_.Label -eq 'Gemini CLI' -or $_.Path -like '*\.gemini\settings.json' }) |
            Should -BeNullOrEmpty
    }
}
