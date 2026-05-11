# ----------------------------------------------------------------------------
# Pinned contract for per-bundle CLI tab-completion registration.
#
# Each curated CLI must be registered by its owning bundle's install script
# via `Register-CliCompletion -Cli <name> -NativeCommand { ... }`. This
# replaces the old central `$CliCompletionNativeMap` in Utils.ps1 — knowledge
# of how to generate completion for a given CLI now lives next to its
# install, not in a shared catalog. Regressions here mean either:
#   (a) a bundle silently lost its native-registration line, or
#   (b) the helper signature changed.
#
# Tagged 'Heavy','CompletionPinned' so the standard fast suite is
# unaffected. Validate-installs.yml will invoke this explicitly.
# ----------------------------------------------------------------------------

Describe 'CliCompletion pinned contract -- per-bundle native registration' -Tag 'Heavy','CompletionPinned' {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'Utils.ps1')
    }

    It '<Cli> is registered with -NativeCommand in <Bundle>' -ForEach @(
        @{ Cli = 'gh';      Bundle = 'GitConfigure.ps1' }
        @{ Cli = 'rg';      Bundle = 'OSBasePackages.ps1' }
        @{ Cli = 'gcloud';  Bundle = 'OSBasePackages.ps1' }
        @{ Cli = 'bw';      Bundle = 'ClientBasePackages.ps1' }
        @{ Cli = 'copilot'; Bundle = 'AIAgents.ps1' }
    ) {
        param($Cli, $Bundle)
        $path = Join-Path $PSScriptRoot $Bundle
        Test-Path $path | Should -BeTrue -Because "bundle script '$Bundle' must exist"
        $content = Get-Content -Raw -Path $path
        # Pattern: Register-CliCompletion ... -Cli <name> ... -NativeCommand
        # Tolerant of param ordering and quoting.
        $pattern = "(?ms)Register-CliCompletion\b[^\r\n]*?-Cli\s+['`"]?$([regex]::Escape($Cli))['`"]?\b[^\r\n]*?-NativeCommand"
        $content | Should -Match $pattern -Because "'$Bundle' must call Register-CliCompletion -Cli $Cli -NativeCommand { ... }"
    }

    It 'uses sentinel version v1' {
        $script:CompletionSentinelVersion | Should -Be 'v1'
    }

    It 'Register-CliCompletion exposes the -NativeCommand parameter' {
        (Get-Command Register-CliCompletion).Parameters.ContainsKey('NativeCommand') | Should -BeTrue
        (Get-Command Register-CliCompletion).Parameters['NativeCommand'].ParameterType | Should -Be ([scriptblock])
    }
}
