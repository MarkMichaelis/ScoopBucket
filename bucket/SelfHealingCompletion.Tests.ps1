#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# ----------------------------------------------------------------------------
# Self-healing native-completion adoption (#278).
#
# Resolve-SelfHealingCompleter prefers a detected native completion helper over
# a hand-curated fallback and emits a low-priority advisory ONLY when it
# supersedes a hand-curated block (output differs). Find-NativeCompletionHelper
# detects a real helper by the hardened Register-ArgumentCompleter marker and
# never matches loose help/bash text.
#
# Tagged 'Light' -- the resolver tests inject a stub detector (no processes);
# the detector tests use tiny self-contained shims on a temp PATH.
# ----------------------------------------------------------------------------

Describe 'Resolve-SelfHealingCompleter' -Tag 'Light','SelfHealing' {

    BeforeAll {
        $psd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $psd1) { Import-Module $psd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
    }

    It 'adopts native output and warns when a helper supersedes the hand-curated fallback' {
        InModuleScope MarkMichaelis.ScoopBucket {
            $detector = {
                param($Cli)
                [pscustomobject]@{
                    Cli        = $Cli
                    Invocation = "$Cli completion powershell"
                    Output     = "Register-ArgumentCompleter -Native -CommandName $Cli -ScriptBlock { 'native' }"
                }
            }
            $result = Resolve-SelfHealingCompleter -Cli 'demo' `
                -FallbackOutput "Register-ArgumentCompleter -Native -CommandName demo -ScriptBlock { 'curated' }" `
                -Detector $detector -SourceHint 'bucket/Demo.ps1' `
                -WarningVariable warn -WarningAction SilentlyContinue

            $result.Healed | Should -BeTrue -Because 'a superseding native helper was detected'
            $result.Output | Should -Match "'native'" -Because 'the native helper output must be adopted'
            $result.Output | Should -Not -Match "'curated'" -Because 'the hand-curated fallback is superseded'
            $warn | Should -Not -BeNullOrEmpty -Because 'adoption must emit the low-priority cleanup advisory'
            ($warn -join ' ') | Should -Match 'can be removed' -Because 'the advisory nudges deleting the curated block'
            ($warn -join ' ') | Should -Match 'bucket/Demo.ps1' -Because 'the advisory includes the source hint'
        }
    }

    It 'returns the fallback unchanged and stays silent when no native helper exists' {
        InModuleScope MarkMichaelis.ScoopBucket {
            $detector = { param($Cli) $null }
            $result = Resolve-SelfHealingCompleter -Cli 'demo' `
                -FallbackOutput 'CURATED-BLOCK' -Detector $detector `
                -WarningVariable warn -WarningAction SilentlyContinue

            $result.Healed | Should -BeFalse
            $result.Output | Should -Be 'CURATED-BLOCK'
            $warn | Should -BeNullOrEmpty -Because 'no native helper means no advisory'
        }
    }

    It 'stays silent when the fallback already IS the native helper (native-sourced, e.g. gh)' {
        InModuleScope MarkMichaelis.ScoopBucket {
            $same = "Register-ArgumentCompleter -Native -CommandName gh -ScriptBlock { }"
            $detector = {
                param($Cli)
                [pscustomobject]@{ Cli = $Cli; Invocation = "$Cli completion -s powershell"; Output = $same }
            }
            $result = Resolve-SelfHealingCompleter -Cli 'gh' -FallbackOutput $same `
                -Detector $detector -WarningVariable warn -WarningAction SilentlyContinue

            $result.Healed | Should -BeFalse -Because 'identical output is not an upgrade'
            $warn | Should -BeNullOrEmpty -Because 'native-sourced completers must not nag'
        }
    }
}

Describe 'Find-NativeCompletionHelper' -Tag 'Light','SelfHealing' {

    BeforeAll {
        $psd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
        if (Test-Path $psd1) { Import-Module $psd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

        $script:shimDir = Join-Path ([System.IO.Path]::GetTempPath()) ("FNCH-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:shimDir -Force | Out-Null

        # Positive shim: emits a real Register-ArgumentCompleter line.
        Set-Content -Path (Join-Path $script:shimDir 'shimyes.cmd') -Encoding Ascii -Value @(
            '@echo off'
            'echo Register-ArgumentCompleter -Native -CommandName shimyes -ScriptBlock { }'
        )
        # Negative shim: emits bash-style completion text WITHOUT the marker.
        Set-Content -Path (Join-Path $script:shimDir 'shimno.cmd') -Encoding Ascii -Value @(
            '@echo off'
            'echo complete -F _shimno shimno   # bash completion, no completer cmdlet'
        )

        $script:origPath = $env:PATH
        $env:PATH = "$script:shimDir;$env:PATH"
    }

    AfterAll {
        $env:PATH = $script:origPath
        if (Test-Path $script:shimDir) { Remove-Item -Recurse -Force $script:shimDir -ErrorAction SilentlyContinue }
    }

    It 'returns $null for a CLI that is not on PATH' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Find-NativeCompletionHelper -Cli 'no-such-cli-xyzzy' | Should -BeNullOrEmpty
        }
    }

    It 'detects a shim that emits Register-ArgumentCompleter' {
        InModuleScope MarkMichaelis.ScoopBucket {
            $helper = Find-NativeCompletionHelper -Cli 'shimyes'
            $helper | Should -Not -BeNullOrEmpty
            $helper.Cli | Should -Be 'shimyes'
            $helper.Output | Should -Match 'Register-ArgumentCompleter'
            $helper.Invocation | Should -Match '^shimyes '
        }
    }

    It 'does NOT detect bash-style completion text (guards against loose matching)' {
        InModuleScope MarkMichaelis.ScoopBucket {
            Find-NativeCompletionHelper -Cli 'shimno' | Should -BeNullOrEmpty `
                -Because 'a bare "complete"/"completion" token must not count as a PowerShell completer'
        }
    }
}
