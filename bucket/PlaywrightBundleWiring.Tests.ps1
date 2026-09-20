#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for how the Playwright package is wired into the
    DeveloperBasePackages and AIAgents aggregators (issue #417).

.DESCRIPTION
    Playwright is now a first-class package rather than a side effect of the
    AIAgents MCP configuration step. Two aggregators consume it:

      * DeveloperBasePackages -- installs it with the rest of the dev group
        and owns the `playwright` completion registration alongside the
        member manifest.
      * AIAgents -- installs it because the `playwright` MCP server drives a
        real Chromium instance, and declares it as a DependsOn of
        'MCP Server Configuration' so the browser exists before the server is
        wired up. This entry is deliberately install-only: re-declaring
        CliCommands/Completion in a second bundle would make the profile-block
        registration order-dependent (the rule established for node/npm/npx
        in #222).

    Tagged 'Light' -- harvests declarative [Package] entries and reads the
    MCP helper as text; no install side effects.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

    $script:pkgs = @(Get-Package -BucketPath $PSScriptRoot)
    $script:dev  = @($script:pkgs | Where-Object { $_.Bundle -eq 'DeveloperBasePackages' -and $_.Name -eq 'Playwright' })
    $script:ai   = @($script:pkgs | Where-Object { $_.Bundle -eq 'AIAgents' -and $_.Name -eq 'Playwright' })
    $script:mcp  = @($script:pkgs | Where-Object { $_.Bundle -eq 'AIAgents' -and $_.Name -eq 'MCP Server Configuration' })
    $script:McpHelper = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'AIAgents.Mcp.ps1')
}

Describe 'DeveloperBasePackages: Playwright entry (issue #417)' -Tag 'Light','Bundle','Completion' {

    It 'declares exactly one Playwright entry' {
        $script:dev.Count | Should -Be 1
    }

    It 'installs it from this bucket''s own manifest' {
        $script:dev[0].Installer | Should -Be 'scoop'
        $script:dev[0].Id | Should -Be 'MarkMichaelis/Playwright'
    }

    It 'declares CliCommands=playwright with a curated completer' {
        @($script:dev[0].CliCommands) | Should -Be @('playwright')
        $script:dev[0].Completion | Should -Be 'auto'
        $script:dev[0].HasNativeCommandScript | Should -BeTrue
        foreach ($expected in 'test','install','codegen','show-report') {
            $script:dev[0].ExpectedCompletions['playwright'] | Should -Contain $expected
        }
    }

    It 'renders a Register-ArgumentCompleter -Native for playwright' {
        $rendered = $script:dev[0].NativeCommandOutputs['playwright']
        $rendered | Should -Match 'Register-ArgumentCompleter\s+-Native'
        $rendered | Should -Match '-CommandName\s+playwright'
    }
}

Describe 'AIAgents: Playwright entry (issue #417)' -Tag 'Light','Bundle' {

    It 'declares exactly one Playwright entry' {
        $script:ai.Count | Should -Be 1
    }

    It 'installs it from this bucket''s own manifest' {
        $script:ai[0].Installer | Should -Be 'scoop'
        $script:ai[0].Id | Should -Be 'MarkMichaelis/Playwright'
    }

    It 'requires Node.js first (npm carries the global install)' {
        @($script:ai[0].DependsOn) | Should -Contain 'Node.js'
    }

    It 'is install-only: no second completion registration for playwright (#222)' {
        @($script:ai[0].CliCommands).Count | Should -Be 0
        $script:ai[0].Completion | Should -Be 'none'
        $script:ai[0].HasNativeCommandScript | Should -BeFalse
    }

    It 'gates MCP server configuration on Playwright being installed' {
        $script:mcp.Count | Should -Be 1
        @($script:mcp[0].DependsOn) | Should -Contain 'Playwright'
    }
}

Describe 'AIAgents MCP configuration no longer installs Playwright itself' -Tag 'Light','Bundle' {

    It 'does not npm-install @playwright/test' {
        $script:McpHelper | Should -Not -Match "(?i)Get-AIAgentsNpmInstallArgument\s+-Package\s+'@playwright/test'"
    }

    It 'does not download browsers' {
        $script:McpHelper | Should -Not -Match '(?i)install\s+chromium'
    }

    It 'warns when no Playwright runtime is reachable' {
        $script:McpHelper | Should -Match '(?i)Write-Warning[^\r\n]*playwright'
    }
}
