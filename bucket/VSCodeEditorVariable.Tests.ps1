#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Pins the EDITOR machine-variable contract on the Visual Studio Code
    package entries (issue #419).

.DESCRIPTION
    Installing VS Code now also points EDITOR at `code --wait`, so every CLI
    tool that shells out to an editor (git without core.editor, npm, gh, ...)
    opens VS Code and waits for the file to be saved and closed.

    Three things have to stay true, and each is a real regression risk:

      * `--wait` must be part of the value. Without it `code` forks and returns
        immediately and the calling tool reads back an unedited file -- the
        single most common way this setting is gotten wrong.
      * The variable must be written at Machine scope, not User.
      * Both bundles that declare VS Code (OSBasePackages and
        DeveloperBasePackages) must carry the SAME ConfigScript.
        Update-Package resolves a -Name to the first bundle that declares it,
        so a hook on only one of them would stop re-applying depending on
        which declaration won -- the hazard fixed for Playwright in #417.

    Tagged 'Light'. The one test that actually executes the hook forces the
    unelevated path, so it can never write a machine-scope variable.
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

    function Get-VSCodePackage {
        param([string]$BundlePath)
        & (Get-Module MarkMichaelis.ScoopBucket) {
            param($bundle) Get-BundlePackageObjects -BundlePath $bundle | Where-Object Name -eq 'Visual Studio Code'
        } $BundlePath
    }

    $script:Packages = @{}
    foreach ($name in $script:Bundles.Keys) {
        $script:Packages[$name] = Get-VSCodePackage -BundlePath $script:Bundles[$name]
    }
}

Describe 'Visual Studio Code sets EDITOR machine-wide (issue #419)' -Tag 'Light','Bundle' {

    It 'declares a configuration hook on the <_> entry' -ForEach @('OSBasePackages','DeveloperBasePackages') {
        $pkg = $script:Packages[$_]
        @($pkg).Count | Should -Be 1 -Because "$_ must declare Visual Studio Code exactly once"
        $pkg.ConfigScript | Should -Not -BeNullOrEmpty -Because 'EDITOR is re-applied on every install AND update'
    }

    It 'sets EDITOR to "code --wait" at Machine scope in <_>' -ForEach @('OSBasePackages','DeveloperBasePackages') {
        $body = $script:Packages[$_].ConfigScript.ToString()
        $body | Should -Match "SetEnvironmentVariable\('EDITOR'" `
            -Because 'the hook must write the EDITOR variable itself'
        $body | Should -Match "'Machine'" `
            -Because 'a User-scope value would not reach services, scheduled tasks or other accounts'
        $body | Should -Match "'code --wait'" `
            -Because 'without --wait, code returns immediately and the caller reads an unedited file'
        $body | Should -Not -Match "'User'" `
            -Because 'the request was explicitly for a machine-wide value'
    }

    It 'carries an identical hook in both bundles' {
        # Both bundle files use the same line-ending convention, so this is an
        # exact comparison. If one copy is edited, this fails rather than
        # letting the two silently diverge.
        $bodies = @($script:Packages.Values | ForEach-Object { $_.ConfigScript.ToString() })
        @($bodies).Count | Should -Be 2
        @($bodies | Select-Object -Unique).Count | Should -Be 1
    }
}

Describe 'EDITOR hook degrades safely without elevation' -Tag 'Light','Bundle' {

    BeforeAll {
        $script:OriginalSessionEditor = $env:EDITOR
        $script:MachineEditorBefore = [Environment]::GetEnvironmentVariable('EDITOR', 'Machine')
    }

    AfterAll {
        $env:EDITOR = $script:OriginalSessionEditor
    }

    It 'warns instead of throwing, and leaves the machine value alone' {
        # Machine scope needs admin. A bundle run from a normal shell must
        # still complete -- a throw here would fail the whole package.
        Mock Test-IsElevated { $false }

        $pkg = $script:Packages['OSBasePackages']
        { & $pkg.ConfigScript $pkg 3>&1 | Out-Null } | Should -Not -Throw

        [Environment]::GetEnvironmentVariable('EDITOR', 'Machine') |
            Should -Be $script:MachineEditorBefore -Because 'an unelevated run must not attempt the write'
    }

    It 'still points the current session at VS Code' {
        Mock Test-IsElevated { $false }

        $env:EDITOR = 'notepad'
        $pkg = $script:Packages['OSBasePackages']
        & $pkg.ConfigScript $pkg 3>&1 | Out-Null

        $env:EDITOR | Should -Be 'code --wait' `
            -Because 'the first git commit after an install should not need a fresh shell'
    }
}
