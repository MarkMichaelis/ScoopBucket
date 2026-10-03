#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first regression for the OSBasePackages ripgrep entry (#465).

.DESCRIPTION
    ripgrep was the one entry in the bucket whose scoop declaration carried a
    VERSION-based justification:

        'scoop main/ripgrep gives v14+, required for --generate complete-powershell.'

    That exception has expired. winget now publishes BurntSushi.ripgrep.MSVC at
    15.2.0 -- the same version scoop's main/ripgrep ships, built from the
    identical upstream artifact:

        PS> winget show --id BurntSushi.ripgrep.MSVC --exact --scope machine
        Version: 15.2.0
        Installer Type: portable (zip)
        Installer Url: https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-pc-windows-msvc.zip

    and the winget manifest is InstallerType: zip / NestedInstallerType: portable
    with `PortableCommandAlias: rg`, so the single shim the declaration promises
    survives the move. The v14+ floor is met with a major version to spare, so
    README rule 1 (winget first for CLIs) applies with no fall-through condition.

    #462/#463 corrected rclone, which had copied THIS entry's declaration without
    checking whether its justification applied. This test exists so the reverse
    cannot happen quietly: it pins the engine, the Id, and the fact that native
    completion is a property of the binary rather than of the installer.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) {
        Import-Module $scoopBucketPsd1 -Force
    } else {
        Import-Module MarkMichaelis.ScoopBucket -Force
    }
    $script:rg = Get-Package -BucketPath $PSScriptRoot -Name 'ripgrep'
}

Describe 'OSBasePackages: ripgrep' -Tag 'Light','Bundle' {

    It 'declares the ripgrep package exactly once' {
        @($script:rg).Count | Should -Be 1
    }

    It 'is declared in the OSBasePackages bundle' {
        $script:rg.Bundle | Should -Be 'OSBasePackages'
    }

    It 'installs from winget as BurntSushi.ripgrep.MSVC (#465)' {
        # winget carries 15.2.0, the same version and artifact as main/ripgrep,
        # so the v14+ exception that kept this entry on scoop no longer applies.
        $script:rg.Installer | Should -Be 'winget'
        $script:rg.Id        | Should -Be 'BurntSushi.ripgrep.MSVC'
    }

    It 'installs machine-scope (no Scope override -- winget resolves --scope machine)' {
        "$($script:rg.Scope)" | Should -Not -Be 'user'
    }

    It 'declares rg as the only CliCommand (matches the single PortableCommandAlias)' {
        @($script:rg.CliCommands) | Should -Be @('rg')
    }

    It 'uses native completion, which is a property of the binary not the engine' {
        $script:rg.Completion             | Should -Be 'native'
        $script:rg.NativeCompletionKind   | Should -Be 'native'
        $script:rg.HasNativeCommandScript | Should -BeTrue
    }

    It 'declares ExpectedCompletions covering real rg flags' {
        $script:rg.ExpectedCompletions | Should -Not -BeNullOrEmpty
        $script:rg.ExpectedCompletions.ContainsKey('rg') | Should -BeTrue
        $expected = @($script:rg.ExpectedCompletions['rg'])
        $expected.Count | Should -BeGreaterThan 0
        foreach ($flag in '--help','--version') {
            $expected | Should -Contain $flag -Because "'$flag' is a documented rg flag"
        }
    }

    It 'records the engine rationale in Notes so the stale v14 reason is not reinstated' {
        $script:rg.Notes | Should -Not -BeNullOrEmpty
        $script:rg.Notes | Should -Match 'winget'
    }
}
