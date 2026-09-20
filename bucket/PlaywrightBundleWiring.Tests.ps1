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
        wired up.

    All three declarations (both aggregators plus the member manifest) must
    stay identical in CLI/completion terms. Update-Package and
    Uninstall-Package resolve a -Name to the first bundle declaring it, so a
    declaration that drops CliCommands would silently orphan the `playwright`
    completer on uninstall and stop refreshing it on update. Identical blocks
    also sidestep the #222 double-registration rule, which is about bundles
    writing *competing* profile blocks for one CLI.

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

    It 'gates MCP server configuration on Playwright being installed' {
        $script:mcp.Count | Should -Be 1
        @($script:mcp[0].DependsOn) | Should -Contain 'Playwright'
    }
}

Describe 'Every Playwright declaration registers the same completer (issue #417)' -Tag 'Light','Bundle','Completion' {

    # Update-Package and Uninstall-Package resolve a -Name to the FIRST bundle
    # that declares it, and AIAgents sorts ahead of DeveloperBasePackages. If
    # the declarations drift -- one of them dropping CliCommands, or the flag
    # lists diverging -- `Uninstall-Package Playwright` silently leaves an
    # orphaned completer in the profile and `Update-Package Playwright` stops
    # refreshing it, depending on which declaration happens to win. Identical
    # declarations also make the #222 double-registration rule moot: blocks
    # that are identical cannot compete.

    BeforeAll {
        $script:AllPlaywright = @($script:pkgs | Where-Object { $_.Name -eq 'Playwright' })
    }

    It 'declares Playwright in exactly three places (member manifest + both aggregators)' {
        @($script:AllPlaywright | ForEach-Object { $_.Bundle } | Sort-Object) |
            Should -Be @('AIAgents','DeveloperBasePackages','Playwright')
    }

    It 'declares playwright as a CLI everywhere, so uninstall always cleans up the completer' {
        foreach ($p in $script:AllPlaywright) {
            @($p.CliCommands) | Should -Be @('playwright') -Because "$($p.Bundle) must declare the CLI"
            $p.Completion | Should -Be 'auto' -Because "$($p.Bundle) must register completion"
        }
    }

    It 'renders an identical completer from every declaration' {
        # Normalize line endings: the bundle files themselves differ (one is
        # CRLF, the rest LF), which is invisible in the registered block.
        $rendered = @($script:AllPlaywright | ForEach-Object { ($_.NativeCommandOutputs['playwright'] -replace "`r", '') })
        @($rendered | Where-Object { $_ }).Count | Should -Be $script:AllPlaywright.Count
        @($rendered | Select-Object -Unique).Count | Should -Be 1
    }

    It 'promises the same completions from every declaration' {
        $sets = @($script:AllPlaywright | ForEach-Object { ($_.ExpectedCompletions['playwright'] | Sort-Object) -join ',' })
        @($sets | Select-Object -Unique).Count | Should -Be 1
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
