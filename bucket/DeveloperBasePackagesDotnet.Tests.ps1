#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for the .NET SDK entry in DeveloperBasePackages
    (issue #466).

.DESCRIPTION
    The entry used to declare Installer='scoop' with Id='main/dotnet', a
    manifest that does not exist -- scoop's main bucket ships `dotnet-sdk`,
    not `dotnet`. `scoop install main/dotnet` therefore failed outright, so
    the `dotnet` DependsOn target of Aspire / Avalonia (and the dotnetTool
    engine's "dotnet not on PATH. Install the .NET SDK first" guard) was
    never actually satisfied by this bundle.

    The entry now installs the .NET SDK through winget -- README rule 1,
    and the same shape as the Python entry in this bundle, which is also
    pinned to a winget id that carries an explicit version
    (Python.Python.3.14). winget publishes no floating "latest SDK" id, so
    the major version is part of the id and the policy for bumping it is
    recorded in Notes.

    These tests fail if the entry reverts to a non-resolving scoop id, loses
    its machine scope, or drops the recorded major-version policy.

    Completion behaviour for the same entry is covered separately by
    DotnetNativeCompletion.Tests.ps1 (issue #228); this file deliberately
    only pins the install engine and target.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
    $script:pkgs = @(Get-Package -BucketPath $PSScriptRoot)
    $script:dotnet = @($script:pkgs | Where-Object { $_.Bundle -eq 'DeveloperBasePackages' -and $_.Name -eq 'dotnet' })
}

Describe 'DeveloperBasePackages: .NET SDK install target (issue #466)' -Tag 'Light', 'Bundle' {

    It 'declares exactly one dotnet entry in DeveloperBasePackages' {
        $script:dotnet.Count | Should -Be 1
    }

    It 'installs the .NET SDK through winget' {
        $script:dotnet[0].Installer | Should -Be 'winget' `
            -Because 'README rule 1 prefers winget, and the previous scoop id main/dotnet resolved to no manifest at all (#466)'
    }

    It 'targets a real winget .NET SDK id' {
        # winget ships only version-pinned SDK ids (Microsoft.DotNet.SDK.8 /
        # .9 / .10 / .Preview); there is no floating latest-SDK id, so the
        # major version is necessarily part of the id.
        $script:dotnet[0].Id | Should -Be 'Microsoft.DotNet.SDK.10'
    }

    It 'installs machine-wide so dotnet is on PATH for every session' {
        # The dotnetTool engine and the Aspire / Avalonia PostInstallScripts
        # all require `dotnet` resolvable from a fresh shell; a user-scope
        # install would not put it on the machine PATH.
        $script:dotnet[0].Scope | Should -Not -Be 'user'
    }

    It 'records the major-version pin policy in Notes' {
        $script:dotnet[0].Notes | Should -Match 'Microsoft\.DotNet\.SDK\.\d+' `
            -Because 'the pinned id has to be maintained across .NET releases, so the policy belongs in Notes (#466 acceptance criteria)'
        $script:dotnet[0].Notes | Should -Match '(?i)major'
    }

    It "keeps the name 'dotnet' that other packages DependsOn" {
        # Aspire (and the Avalonia bundle's documented prerequisite) name
        # this entry 'dotnet'; renaming it breaks their closure. The
        # resolution order itself is covered by DependsOnClosure.Tests.ps1.
        $script:dotnet[0].Name | Should -Be 'dotnet'
    }
}
