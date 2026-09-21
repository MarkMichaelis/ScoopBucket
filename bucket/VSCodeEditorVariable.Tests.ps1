#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Pins the EDITOR wiring on the Visual Studio Code package entries (#419).

.DESCRIPTION
    Installing VS Code points EDITOR at `code --wait`, so every CLI tool that
    shells out to an editor (git without core.editor, npm, gh, ...) opens
    VS Code and waits for the file to be saved and closed.

    The decision itself -- when to claim EDITOR and when to leave a deliberately
    chosen editor alone -- lives in Set-DefaultEditorVariable and is covered by
    EditorVariable.Tests.ps1 beside it. What this file pins is the WIRING:

      * both bundles that declare VS Code (OSBasePackages and
        DeveloperBasePackages) carry the hook, as a ConfigScript so it re-runs
        on updates rather than only on first install;
      * both copies are identical. Update-Package resolves a -Name to the first
        bundle that declares it, so a hook on only one of them would stop
        re-applying depending on which declaration won -- the hazard fixed for
        Playwright in #417;
      * the hook delegates rather than inlining the logic, which is what makes
        the two copies identical by construction.

    Tagged 'Light'. Nothing here executes the hook, so no environment variable
    is touched.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) {
        Import-Module $scoopBucketPsd1 -Force
    } else {
        Import-Module MarkMichaelis.ScoopBucket -Force
    }

    $script:Bundles = @{
        OSBasePackages        = Join-Path $PSScriptRoot 'OSBasePackages.ps1'
        DeveloperBasePackages = Join-Path $PSScriptRoot 'DeveloperBasePackages.ps1'
    }

    $script:Packages = @{}
    foreach ($name in $script:Bundles.Keys) {
        $script:Packages[$name] = & (Get-Module MarkMichaelis.ScoopBucket) {
            param($bundle)
            Get-BundlePackageObjects -BundlePath $bundle | Where-Object Name -eq 'Visual Studio Code'
        } $script:Bundles[$name]
    }
}

Describe 'Visual Studio Code wires up EDITOR (issue #419)' -Tag 'Light','Bundle' {

    It 'declares a configuration hook on the <_> entry' -ForEach @('OSBasePackages','DeveloperBasePackages') {
        $pkg = $script:Packages[$_]
        @($pkg).Count | Should -Be 1 -Because "$_ must declare Visual Studio Code exactly once"
        $pkg.ConfigScript | Should -Not -BeNullOrEmpty `
            -Because 'ConfigScript re-applies on every install AND update; PostInstallScript would not'
    }

    It 'delegates the decision instead of inlining it in <_>' -ForEach @('OSBasePackages','DeveloperBasePackages') {
        $body = $script:Packages[$_].ConfigScript.ToString()
        $body | Should -Match 'Set-DefaultEditorVariable' `
            -Because 'the ownership/elevation rules belong in one tested place'
        $body | Should -Not -Match 'SetEnvironmentVariable' `
            -Because 'an inlined write would drift between the two copies and escape the module tests'
    }

    It 'carries an identical hook in both bundles' {
        $bodies = @($script:Packages.Values | ForEach-Object { $_.ConfigScript.ToString() -replace "`r", '' })
        @($bodies).Count | Should -Be 2
        @($bodies | Select-Object -Unique).Count | Should -Be 1 `
            -Because 'Update-Package resolves a -Name to the first declaring bundle (#417)'
    }

    It 'exports the hook so it can be re-run by hand' {
        (Get-Command Set-DefaultEditorVariable -Module MarkMichaelis.ScoopBucket -ErrorAction SilentlyContinue) |
            Should -Not -BeNullOrEmpty
    }
}
