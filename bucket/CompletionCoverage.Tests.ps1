#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# ----------------------------------------------------------------------------
# Completion coverage guard (#278).
#
# Procedurally-installed CLIs (winget/choco/scoop install lines, JSON
# manifests) bypass Package.Validate's "CliCommands => Completion" check, so a
# new CLI can ship with no tab-completion and nothing notices -- which is how
# pwsh/powershell slipped through. CompletionCoverage.psd1 is the source of
# truth for those CLIs; this test enforces it in both directions:
#
#   * every catalog entry has a real backing registration in its Script, and
#   * every `Register-CliCompletion -Cli <x>` across bucket/*.ps1 is catalogued.
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
                    [regex]::Matches($text, "Register-CliCompletion\b[^\r\n]*?-Cli\s+['""]?(?<cli>[\w.-]+)") |
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
                $pattern = "(?ms)Register-CliCompletion\b[^\r\n]*?-Cli\s+['`"]?$([regex]::Escape($Cli))['`"]?\b[^\r\n]*?-NativeCommand"
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
