#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first pin for the ClientBasePackages PowerToys entry. PowerToys is
    installed for its maintained Mouse Without Borders module (closes #358),
    replacing the unmaintained standalone Microsoft.MouseWithoutBorders 2.2.1
    build.

.DESCRIPTION
    A plain winget GUI app is otherwise only covered structurally by the
    data-driven Bundles.Tests.ps1, which validates whatever packages exist but
    does not pin any specific package's presence. This focused test fails with a
    named diagnostic if the PowerToys entry is removed or its winget Id drifts,
    so a revert breaks for a behavioral reason rather than silently dropping
    Mouse Without Borders from the bucket.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) {
        Import-Module $scoopBucketPsd1 -Force
    } else {
        Import-Module MarkMichaelis.ScoopBucket -Force
    }
    $script:powerToys = Get-Package -BucketPath $PSScriptRoot -Name 'PowerToys'
}

Describe 'ClientBasePackages: PowerToys (Mouse Without Borders)' -Tag 'Light', 'Bundle' {

    It 'declares the PowerToys package exactly once' {
        @($script:powerToys).Count | Should -Be 1
    }

    It 'installs via winget' {
        $script:powerToys.Installer | Should -Be 'winget'
    }

    It 'targets the Microsoft.PowerToys winget id (ships the maintained Mouse Without Borders)' {
        $script:powerToys.Id | Should -Be 'Microsoft.PowerToys'
    }
}
