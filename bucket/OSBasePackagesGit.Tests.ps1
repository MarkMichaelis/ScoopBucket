#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first test for the OSBasePackages Git entry (#498).

.DESCRIPTION
    Git is a winget package like any other, so Update-Package keeps it current.
    install.ps1 needs a git before any bucket exists and gets one from scoop's
    main/mingit; the entry must name that copy as its predecessor so the
    bootstrap ends with exactly one git, owned by this declaration.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) {
        Import-Module $scoopBucketPsd1 -Force
    } else {
        Import-Module MarkMichaelis.ScoopBucket -Force
    }
    $script:mod = Get-Module MarkMichaelis.ScoopBucket
    $script:git = Get-Package -BucketPath $PSScriptRoot -Name 'Git'
    # Get-Package's view omits the predecessor pair; the install driver reads this.
    $script:gitDeclaration = & $script:mod {
        param($BundlePath)
        Get-BundlePackageObjects -BundlePath $BundlePath | Where-Object Name -EQ 'Git'
    } (Join-Path $PSScriptRoot 'OSBasePackages.ps1')
    $script:installSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\install.ps1')
    $script:bundleSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'OSBasePackages.ps1')
}

Describe 'OSBasePackages: Git' -Tag 'Light','Bundle' {

    It 'declares the Git package exactly once' {
        @($script:git | Where-Object { $_ }).Count | Should -Be 1
    }

    It 'is declared in the OSBasePackages bundle' {
        $script:git.Bundle | Should -Be 'OSBasePackages'
    }

    It 'installs from winget as Git.Git' {
        $script:git.Installer | Should -Be 'winget'
        $script:git.Id        | Should -Be 'Git.Git'
    }

    It 'installs machine-scope' {
        "$($script:git.Scope)" | Should -Not -Be 'user'
    }

    It 'names exactly what the bootstrap installs as its predecessor' {
        $script:gitDeclaration.PreviousInstaller | Should -Be 'scoop'
        $script:gitDeclaration.PreviousId        | Should -Be 'main/mingit'
        $script:installSource | Should -Match "install -g $([regex]::Escape($script:gitDeclaration.PreviousId))"
    }

    It 'stands aside for posh-git rather than racing it in the profile' {
        $script:bundleSource | Should -Match "Join-Path ``\`$_ 'posh-git'"
    }

    It 'migrates a bootstrap git that answers on PATH instead of refusing it' {
        $conflict = & $script:mod {
            param($Package)
            Get-PackageEngineConflict -Package $Package `
                -EngineRoot @{ winget = @('C:\Program Files\WinGet'); scoop = @('C:\ProgramData\scoop') } `
                -CommandResolver { 'C:\ProgramData\scoop\apps\mingit\current\cmd\git.exe' }
        } $script:gitDeclaration
        $conflict.Engine   | Should -Be 'scoop'
        $conflict.Declared | Should -BeTrue
    }

    It 'leaves a vendor Program Files git to the winget upgrade path' {
        $conflict = & $script:mod {
            param($Package)
            Get-PackageEngineConflict -Package $Package `
                -EngineRoot @{ winget = @('C:\Program Files\WinGet'); scoop = @('C:\ProgramData\scoop') } `
                -CommandResolver { 'C:\Program Files\Git\cmd\git.exe' }
        } $script:gitDeclaration
        $conflict | Should -BeNullOrEmpty
    }
}
