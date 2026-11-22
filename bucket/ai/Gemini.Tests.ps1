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

}

Describe 'Gemini: the Heavy-test hint verifies the Gemini app, not the Google app (#534)' -Tag 'Light', 'Bundle' {

    # The hint decides on winget's exit code, as the engine's own installed
    # check (Test-WingetPackageInstalled) does. The old hint tested for the
    # Google app's google.exe, so it reported the wrong app either way.
    BeforeAll {
        $script:hint = (& (Join-Path $script:bucketRoot 'ManifestTestHints.ps1'))['Gemini']
    }

    It 'is a Custom check' {
        $script:hint.Verify | Should -Be 'Custom'
    }

    It 'reports installed when winget finds Google.GeminiDesktop' {
        Mock winget { $global:LASTEXITCODE = 0 }
        & $script:hint.Script | Should -BeTrue
        Should -Invoke winget -Times 1 -Exactly -ParameterFilter { $args -contains 'Google.GeminiDesktop' }
    }

    It 'reports missing when winget does not find Google.GeminiDesktop' {
        Mock winget { $global:LASTEXITCODE = -1978335212 }  # APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND
        & $script:hint.Script | Should -BeFalse
    }
}
