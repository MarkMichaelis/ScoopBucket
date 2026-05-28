#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for AIAgents bundle entries that need
    bundle-specific winget invocation tweaks.

.DESCRIPTION
    Warp ships a Squirrel-based installer whose progress UI pops a
    window during winget install. That is bad UX for interactive
    Install-Package calls and outright broken for headless CI. The
    bucket suppresses it by passing both --silent (installer UI off)
    and --disable-interactivity (winget itself stays non-interactive)
    via the Package.WingetExtraArgs surface.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) {
        Import-Module $scoopBucketPsd1 -Force
    } else {
        Import-Module MarkMichaelis.ScoopBucket -Force
    }
    $script:warpPkg = Get-Package -BucketPath $PSScriptRoot -Name 'Warp'
}

Describe 'AIAgents bundle: Warp winget invocation' -Tag 'Light','Bundle' {

    It 'declares the Warp package exactly once' {
        @($script:warpPkg).Count | Should -Be 1
    }

    It 'passes --silent to suppress the Squirrel installer progress UI' {
        $script:warpPkg.WingetExtraArgs | Should -Contain '--silent'
    }

    It 'passes --disable-interactivity to keep winget itself non-interactive' {
        $script:warpPkg.WingetExtraArgs | Should -Contain '--disable-interactivity'
    }
}

Describe 'AIAgents bundle: Gemini desktop -> Gemini CLI Companions' -Tag 'Light','Bundle' {
    BeforeAll {
        $script:aiPkgs = @(Get-Package -BucketPath $PSScriptRoot -Bundle 'AIAgents')
    }

    It 'Gemini desktop declares Companions=@(Gemini CLI)' {
        $desktop = @($script:aiPkgs | Where-Object Name -EQ 'Gemini')[0]
        $desktop                       | Should -Not -BeNullOrEmpty
        @($desktop.Companions)         | Should -Contain 'Gemini CLI'
    }
}
