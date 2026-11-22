#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Pins the Gemini package to Google's dedicated Gemini desktop app (#534).

.DESCRIPTION
    Google launched a native Gemini app for Windows on 2026-09-10. winget
    carries it as Google.GeminiDesktop, published by Google LLC. It replaces
    the "Google app for desktop" the bucket used to install by rebuilding an
    Omaha download URL scraped from search.google's JavaScript.

    The winget manifest declares a nullsoft installer with Scope: user and no
    machine-scope variant. Without Scope='user' the engine defaults to
    --scope machine, and winget then walks back through manifest versions to
    one that is machine-applicable, silently installing a stale build (the
    Signal failure in #433).
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

    $script:bucketRoot = Split-Path -Parent $PSScriptRoot
    $script:gemini     = @(Get-Package -BucketPath $script:bucketRoot -Name 'Gemini' | Where-Object Bundle -EQ 'Gemini')
}

Describe 'Gemini: installs the Gemini desktop app (#534)' -Tag 'Light', 'Bundle' {

    It 'declares exactly one Gemini package in the Gemini manifest' {
        $script:gemini.Count | Should -Be 1
    }

    It 'installs from winget as Google.GeminiDesktop, the official Google LLC package' {
        $script:gemini[0].Installer | Should -Be 'winget'
        $script:gemini[0].Id        | Should -Be 'Google.GeminiDesktop'
    }

    It 'installs user-scope, the only scope the winget manifest offers' {
        $script:gemini[0].Scope | Should -Be 'user'
    }

    It 'no longer downloads the Google app for desktop' {
        $script = Get-Content -Raw (Join-Path $PSScriptRoot 'Gemini.ps1')
        $script | Should -Not -Match 'GoogleAppInstaller' -Because 'the Omaha Google-app bootstrapper is the retired install path'
        $script | Should -Not -Match '06A8089E-0B65-445D-B5C4-10B0D1B540F2' -Because 'that is the Google app appguid, not Gemini'
    }
}

Describe 'Gemini: the Heavy-test hint verifies the Gemini app, not the Google app (#534)' -Tag 'Light', 'Bundle' {

    BeforeAll {
        $script:hint = (& (Join-Path $script:bucketRoot 'ManifestTestHints.ps1'))['Gemini']
    }

    It 'checks the winget package id' {
        $script:hint.Verify | Should -Be 'Custom'
        $script:hint.Script.ToString() | Should -Match 'Google\.GeminiDesktop'
        $script:hint.Script.ToString() | Should -Not -Match 'google\.exe'
    }
}
