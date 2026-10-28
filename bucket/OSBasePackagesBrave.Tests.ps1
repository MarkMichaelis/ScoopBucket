#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first test for the OSBasePackages Brave browser entry (#478).

.DESCRIPTION
    Brave installs from winget (README rule 1) as Brave.Brave, published by
    Brave Software Inc, which resolves at --scope machine with the standalone
    setup exe. It is one of the OS base packages, like Google Chrome.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) {
        Import-Module $scoopBucketPsd1 -Force
    } else {
        Import-Module MarkMichaelis.ScoopBucket -Force
    }
    $script:brave = Get-Package -BucketPath $PSScriptRoot -Name 'Brave'
}

Describe 'OSBasePackages: Brave' -Tag 'Light','Bundle' {

    It 'declares the Brave package exactly once' {
        @($script:brave | Where-Object { $_ }).Count | Should -Be 1
    }

    It 'is declared in the OSBasePackages bundle' {
        $script:brave.Bundle | Should -Be 'OSBasePackages'
    }

    It 'installs from winget as Brave.Brave (#478)' {
        $script:brave.Installer | Should -Be 'winget'
        $script:brave.Id        | Should -Be 'Brave.Brave'
    }

    It 'installs machine-scope (no Scope override -- winget resolves --scope machine)' {
        "$($script:brave.Scope)" | Should -Not -Be 'user'
    }
}
