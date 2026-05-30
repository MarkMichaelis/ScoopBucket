# ----------------------------------------------------------------------------
# Behavior-first pin: Windows Terminal (wt) ships native PowerShell tab
# completion in-tree, not via PSCompletions.
#
# Phase 2 of the pscompletions -> native conversion (Issue #232). Reference
# Phase 2 conversions: bucket\AIAgents.ps1 (Node.js), bucket\DeveloperBasePackages.ps1
# (devenv). Earlier OSBasePackages native-completion siblings: code, bat, fzf,
# gcloud, es.
#
# Each assertion fails for a behavioral reason if the production change is
# reverted (Completion flips back to 'pscompletions' -> auto goes false;
# NativeCommandScript dropped -> HasNativeCommandScript goes false;
# ExpectedCompletions reverted -> '--window'/'--maximized' missing).
# ----------------------------------------------------------------------------

Describe 'OSBasePackages -- wt native completion (Phase 2)' -Tag 'Light' {

    BeforeAll {
        $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
        $script:wt = @(Get-Package -BucketPath $PSScriptRoot |
            Where-Object { $_.Bundle -eq 'OSBasePackages' -and ($_.CliCommands -contains 'wt') })
        $script:wt.Count | Should -Be 1 -Because 'exactly one OSBasePackages [Package] must own the wt CLI'
    }

    It "wt Package uses Completion='auto' (no longer pscompletions)" {
        $script:wt[0].Completion | Should -Be 'auto'
    }

    It 'wt Package supplies a NativeCommandScript' {
        # Get-Package marshalls Packages across runspaces; the actual
        # scriptblock cannot round-trip, so assert HasNativeCommandScript
        # (the cross-runspace-safe boolean projection).
        $script:wt[0].HasNativeCommandScript | Should -BeTrue
    }

    It 'wt ExpectedCompletions contains documented subcommands and global flags' {
        $expected = $script:wt[0].ExpectedCompletions
        $expected | Should -Not -BeNullOrEmpty
        $expected.ContainsKey('wt') | Should -BeTrue
        $entries = @($expected['wt'])
        $entries.Count | Should -BeGreaterThan 0
        # Sample the documented surface: at least one subcommand AND at least
        # one global flag must be advertised so Tab demonstrably surfaces both.
        $entries | Should -Contain 'new-tab'
        $entries | Should -Contain 'split-pane'
        $entries | Should -Contain '--window'
        $entries | Should -Contain '--maximized'
    }
}
