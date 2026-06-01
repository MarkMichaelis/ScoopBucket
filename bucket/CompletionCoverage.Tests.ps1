#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# ----------------------------------------------------------------------------
# Completion coverage guard (#278).
#
# This is a CATALOG-CONSISTENCY guard, not an install-vector scanner. It does
# NOT discover CLIs from winget/choco/scoop install lines or JSON manifests, and
# on its own it cannot stop a new install line from shipping a CLI with no
# completion -- that still relies on a human adding the CLI to the catalog.
#
# CompletionCoverage.psd1 is a manually maintained catalog of the CLIs the
# bucket wires for completion. This test enforces the catalog in both
# directions so the catalog and the actual registrations never silently
# diverge:
#
#   * every catalog entry has a real backing registration in its Script, and
#   * every `Register-CliCompletion -Cli <x>` across bucket/*.ps1 is catalogued.
#
# (Background: pwsh/powershell originally slipped through because they install
# via procedural scripts that bypass Package.Validate's "CliCommands =>
# Completion" check; the catalog is the manual record that closes that gap.)
#
# Tagged 'Light' -- pure static source analysis, no installed CLIs required.
# ----------------------------------------------------------------------------

Describe 'Completion coverage catalog is honoured' -Tag 'Light','CompletionCoverage' {

    BeforeAll {
        $script:bucketDir = $PSScriptRoot
        $script:catalogPath = Join-Path $script:bucketDir 'CompletionCoverage.psd1'
        $script:catalog = Import-PowerShellDataFile -Path $script:catalogPath
        $script:entries = @($script:catalog.Clis)

        # Every `Register-CliCompletion -Cli <name>` actually present in the
        # bucket scripts (the registrations that must each be catalogued).
        $script:registeredClis = @(
            Get-ChildItem -Path $script:bucketDir -Filter '*.ps1' -File |
                Where-Object { $_.Name -notlike '*.Tests.ps1' } |
                ForEach-Object {
                    $text = Get-Content -Raw -Path $_.FullName
                    # Bounded `[\s\S]` (not `[^\r\n]`) so a registration whose
                    # arguments are split across lines with backticks is still
                    # discovered -- a missed match would silently drop the
                    # catalog requirement for that CLI.
                    [regex]::Matches($text, "Register-CliCompletion\b[\s\S]{0,200}?-Cli\s+['""]?(?<cli>[\w.-]+)") |
                        ForEach-Object { $_.Groups['cli'].Value }
                } | Sort-Object -Unique
        )
    }

    It 'catalog file exists and lists entries' {
        Test-Path $script:catalogPath | Should -BeTrue
        $script:entries.Count | Should -BeGreaterThan 0
    }

    It 'catalog entry <Cli> (<Status>) has a real backing registration in <Script>' -ForEach @(
        # Materialised from the catalog at discovery time so each entry is a
        # separate test case with a meaningful name.
        (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'CompletionCoverage.psd1')).Clis
    ) {
        param($Cli, $Status, $Script, $Activation)

        $scriptPath = Join-Path $PSScriptRoot $Script
        Test-Path $scriptPath | Should -BeTrue -Because "$Script must exist"
        $content = Get-Content -Raw -Path $scriptPath

        switch ($Status) {
            'Registered' {
                # Bounded `[\s\S]` spans tolerate harmless line breaks/backticks
                # between the tokens so a multi-line registration still matches.
                $pattern = "(?ms)Register-CliCompletion\b[\s\S]{0,200}?-Cli\s+['`"]?$([regex]::Escape($Cli))['`"]?\b[\s\S]{0,200}?-NativeCommand"
                $content | Should -Match $pattern -Because "$Script must call Register-CliCompletion -Cli $Cli -NativeCommand { ... }"
            }
            'ModuleActivated' {
                $content | Should -Match $Activation -Because "$Script must activate $Cli completion via /$Activation/"
            }
            default {
                throw "Unknown Status '$Status' for '$Cli' in CompletionCoverage.psd1"
            }
        }
    }

    It 'every procedural Register-CliCompletion registration is catalogued' {
        $catalogued = @($script:entries | ForEach-Object { $_.Cli })
        foreach ($cli in $script:registeredClis) {
            $catalogued | Should -Contain $cli -Because "Register-CliCompletion -Cli $cli must have a CompletionCoverage.psd1 entry"
        }
    }

    It 'all originally-requested + audited CLIs are covered' {
        $required = @('gh','gk','pwsh','powershell','wsl','git','choco','scoop')
        $catalogued = @($script:entries | ForEach-Object { $_.Cli })
        foreach ($cli in $required) {
            $catalogued | Should -Contain $cli -Because "$cli was in scope for #278 and must be catalogued"
        }
    }
}

Describe 'PowerShell.ps1 hand-curated host completers' -Tag 'Light','CompletionCoverage' {

    BeforeAll {
        $script:psInstallSource = Get-Content -Raw -Path (Join-Path $PSScriptRoot 'PowerShell.ps1')
    }

    It 'renders a Register-ArgumentCompleter -Native template' {
        $script:psInstallSource | Should -Match 'Register-ArgumentCompleter -Native -CommandName \$Cli'
    }

    It '<Cli> curated switch list includes <Switch>' -ForEach @(
        @{ Cli = 'pwsh';       Switch = '-NoProfile' }
        @{ Cli = 'pwsh';       Switch = '-File' }
        @{ Cli = 'powershell'; Switch = '-PSConsoleFile' }
        @{ Cli = 'wsl';        Switch = '--install' }
    ) {
        param($Cli, $Switch)
        # The switch list literal must be present in the staticCompleters table.
        $script:psInstallSource | Should -Match ([regex]::Escape("'$Switch'")) -Because "$Cli completer must offer $Switch"
    }
}
