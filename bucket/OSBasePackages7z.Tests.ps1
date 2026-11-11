#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first regression for OSBasePackages 7-Zip entry: native
    PowerShell completion via Completion='auto' + NativeCommandScript
    (Phase 2 of the native-completion migration; replaces the
    pscompletions catalog dependency for 7z). Closes #233.

.DESCRIPTION
    The data-driven cases in Bundles.Tests.ps1 already verify the
    NativeCommandScript emits Register-ArgumentCompleter for every
    declared CliCommand. This focused test pins the bundle-specific
    contract for 7-Zip so a revert to Completion='pscompletions' fails
    here with a clear, named diagnostic instead of getting absorbed
    into a generic data-driven failure.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) {
        Import-Module $scoopBucketPsd1 -Force
    } else {
        Import-Module MarkMichaelis.ScoopBucket -Force
    }
    $script:sevenZip = Get-Package -BucketPath $PSScriptRoot -Name '7-Zip'
    $script:mod = Get-Module MarkMichaelis.ScoopBucket
    # Get-Package's view omits the predecessor pair and ConfigScript; the
    # install driver reads the declaration itself.
    $script:sevenZipDeclaration = & $script:mod {
        param($BundlePath)
        Get-BundlePackageObjects -BundlePath $BundlePath | Where-Object Name -EQ '7-Zip'
    } (Join-Path $PSScriptRoot 'OSBasePackages.ps1')
}

Describe 'OSBasePackages: 7-Zip replaces scoop''s own 7zip (#518)' -Tag 'Light','Bundle' {

    It 'names scoop main/7zip as its predecessor' {
        $script:sevenZipDeclaration.PreviousInstaller | Should -Be 'scoop'
        $script:sevenZipDeclaration.PreviousId        | Should -Be 'main/7zip'
    }

    It 'migrates a scoop 7z shim that answers on PATH instead of refusing it' {
        $conflict = & $script:mod {
            param($Package)
            Get-PackageEngineConflict -Package $Package `
                -EngineRoot @{ winget = @('C:\Program Files\WinGet'); scoop = @('C:\ProgramData\scoop') } `
                -CommandResolver { 'C:\ProgramData\scoop\shims\7z.exe' } `
                -ScoopScopeRoot @{ Global = @('C:\ProgramData\scoop'); User = @() }
        } $script:sevenZipDeclaration
        $conflict.Engine           | Should -Be 'scoop'
        $conflict.Declared         | Should -BeTrue
        $conflict.UninstallCommand | Should -Be 'scoop uninstall -g 7zip'
    }

    # Scoop runs the bundle as a plain script, so the ConfigScript is bound to
    # the bundle's scope, not the module's. Rebuild it unbound -- the harvested
    # copy above was evaluated inside the module and would resolve private
    # functions that fail under scoop (#524).
    It 'runs its ConfigScript outside the module by calling Set-ScoopExternal7Zip' {
        Mock Set-ScoopExternal7Zip { }
        $unbound = [scriptblock]::Create($script:sevenZipDeclaration.ConfigScript.ToString())
        & $unbound
        Should -Invoke Set-ScoopExternal7Zip -Times 1 -Exactly
    }
}

Describe 'Set-ScoopExternal7Zip (#518, #524)' -Tag 'Light','Module' {
    BeforeEach {
        # `scoop` inside the module is the module's wrapper; mock it there or
        # the real scoop config runs.
        Mock -ModuleName MarkMichaelis.ScoopBucket scoop { }
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-EngineRootMap {
            @{ winget = @('C:\Program Files\WinGet'); scoop = @('C:\ProgramData\scoop') }
        }
    }

    It 'tells scoop to extract with a non-scoop 7z so it does not reinstall main/7zip' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-CommandSourcePath { 'C:\Program Files\7-Zip\7z.exe' }
        (Set-ScoopExternal7Zip).Action | Should -Be 'Set'
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket scoop -Times 1 -Exactly -ParameterFilter {
            ($args -join ' ') -eq 'config use_external_7zip true'
        }
    }

    # use_external_7zip makes scoop abort every 7z extraction when no 7z is
    # on PATH -- worse than letting it install its own helper.
    It 'leaves scoop on its own 7zip when no 7z resolves on PATH' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-CommandSourcePath { $null }
        (Set-ScoopExternal7Zip 3>$null).Action | Should -Be 'Skipped'
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket scoop -Times 0 -Exactly
    }

    It 'leaves scoop on its own 7zip when the only 7z on PATH is scoop''s' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-CommandSourcePath { 'C:\ProgramData\scoop\shims\7z.exe' }
        (Set-ScoopExternal7Zip 3>$null).Action | Should -Be 'Skipped'
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket scoop -Times 0 -Exactly
    }

    It 'writes nothing under -WhatIf' {
        Mock -ModuleName MarkMichaelis.ScoopBucket Get-CommandSourcePath { 'C:\Program Files\7-Zip\7z.exe' }
        (Set-ScoopExternal7Zip -WhatIf).Action | Should -Be 'Skipped'
        Should -Invoke -ModuleName MarkMichaelis.ScoopBucket scoop -Times 0 -Exactly
    }
}

Describe 'OSBasePackages: 7-Zip native PowerShell completion' -Tag 'Light','Bundle' {

    It 'declares the 7-Zip package exactly once' {
        @($script:sevenZip).Count | Should -Be 1
    }

    It "uses Completion='auto' (no longer depends on PSCompletions catalog)" {
        $script:sevenZip.Completion | Should -Be 'auto'
    }

    It 'ships a non-null NativeCommandScript so a Register-ArgumentCompleter block is emitted' {
        $script:sevenZip.HasNativeCommandScript | Should -BeTrue
    }

    It 'declares 7z as the only CliCommand (matches the shim shipped by 7Zip.7Zip)' {
        @($script:sevenZip.CliCommands) | Should -Be @('7z')
    }

    It 'declares ExpectedCompletions for 7z covering at least one CLI command and one switch' {
        $script:sevenZip.ExpectedCompletions               | Should -Not -BeNullOrEmpty
        $script:sevenZip.ExpectedCompletions.ContainsKey('7z') | Should -BeTrue
        $expected = @($script:sevenZip.ExpectedCompletions['7z'])
        $expected.Count | Should -BeGreaterThan 0
        # Pin a representative subset: 7z CLI command (a/x/l/t) + a switch (-y).
        ($expected | Where-Object { $_ -in 'a','x','l','t' }) |
            Should -Not -BeNullOrEmpty -Because 'expected completions must include at least one 7z CLI command (a/x/l/t)'
        $expected | Should -Contain '-y' -Because 'expected completions must include at least one 7z switch'
    }

    It "NativeCommandScript output for 7z names the 7z CLI in Register-ArgumentCompleter" {
        $out = [string]$script:sevenZip.NativeCommandOutputs['7z']
        $out | Should -Match 'Register-ArgumentCompleter\s+-Native\s+-CommandName\s+7z'
    }
}
