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
        $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force } 
    }

    # Only CLIs whose `<tool> completion powershell` (or equivalent) is known
    # to emit a real Register-ArgumentCompleter script are pinned here. CLIs
    # that lack a native PowerShell completion subcommand (bw, copilot,
    # gcloud) deliver completion via Invoke-CliCompletionsSweep's PSCompletions
    # fallback instead -- see #73.
    It '<Cli> is registered with -NativeCommand in <Bundle>' -ForEach @(
        @{ Cli = 'gh';      Bundle = 'GitConfigure.ps1' }
        @{ Cli = 'rg';      Bundle = 'OSBasePackages.ps1' }
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

    # Regression guard for #73: these CLIs were intentionally dropped from
    # per-bundle native registration because their `<tool> completion` (or
    # equivalent) subcommand does not emit a PowerShell completion script.
    # Re-adding a Register-CliCompletion -NativeCommand line for any of them
    # would silently produce a dead block (Resolve-CliCompletionSource sees
    # empty output and returns Skipped). Completion for these CLIs is
    # delivered by Invoke-CliCompletionsSweep's PSCompletions fallback.
    It '<Cli> has no per-bundle -NativeCommand wiring (#73)' -ForEach @(
        @{ Cli = 'gcloud'  }
        @{ Cli = 'bw'      }
        @{ Cli = 'copilot' }
    ) {
        param($Cli)
        $bundleScripts = Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' |
            Where-Object { $_.Name -notlike '*.Tests.ps1' -and $_.Name -ne 'Utils.ps1' }
        $pattern = "(?ms)Register-CliCompletion\b[^\r\n]*?-Cli\s+['`"]?$([regex]::Escape($Cli))['`"]?\b[^\r\n]*?-NativeCommand"
        foreach ($f in $bundleScripts) {
            $content = Get-Content -Raw -Path $f.FullName
            $content | Should -Not -Match $pattern -Because "'$($f.Name)' must not wire a native PowerShell completion for $Cli (its CLI does not emit one; see #73)."
        }
    }
}
