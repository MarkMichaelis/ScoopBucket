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

    It 'restores the scrubbed PowerToys settings snapshot during the configuration phase (ConfigScript)' {
        # Closes #368: the committed snapshot (bucket/os/MarkMichaelisPowerToysSettings.jsonc)
        # is reapplied via Import-PowerToysSettings on every install/update (idempotent
        # desired-state configuration), not install-only. Get-Package strips scriptblocks,
        # exposing only the HasConfigScript projection.
        $script:powerToys.HasConfigScript | Should -BeTrue
    }
}

Describe 'ClientBasePackages: committed PowerToys settings snapshot' -Tag 'Light', 'Bundle' {

    BeforeAll {
        # Closes #370: the snapshot lives in the bucket (not the module Data folder)
        # with the MarkMichaelis prefix and a .jsonc extension so Scoop's *.json
        # manifest glob ignores it. The ConfigScript restores from exactly this path.
        $script:snapshotPath = Join-Path $PSScriptRoot 'os\MarkMichaelisPowerToysSettings.jsonc'
    }

    It 'ships the committed snapshot at bucket/os/MarkMichaelisPowerToysSettings.jsonc' {
        Test-Path -LiteralPath $script:snapshotPath -PathType Leaf | Should -BeTrue `
            -Because 'the PowerToys ConfigScript restores from this exact path'
    }

    It 'is valid JSON exposing the snapshot files map' {
        $snapshot = Get-Content -LiteralPath $script:snapshotPath -Raw | ConvertFrom-Json
        $snapshot.files | Should -Not -BeNullOrEmpty
    }

    It 'carries no residual MouseWithoutBorders SecurityKey value (scrubbed)' {
        $snapshot = Get-Content -LiteralPath $script:snapshotPath -Raw | ConvertFrom-Json
        $mwb = $snapshot.files.'MouseWithoutBorders/settings.json'
        $mwb | Should -Not -BeNullOrEmpty -Because 'the captured machine had Mouse Without Borders settings'
        $mwb.properties.SecurityKey.value | Should -BeNullOrEmpty `
            -Because 'the SecurityKey must be neutralized before committing to a public repo'
    }
}
