<#
.SYNOPSIS
    Light tests for the migrated (declarative) DeveloperBasePackages.ps1.

.DESCRIPTION
    Asserts the bundle exposes the expected [Package[]] collection via
    Get-Package without performing any real installs.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Utils.ps1')
    Import-Module (Get-ScoopBucketModulePath) -Force
    $script:pkgs = Get-Package -Bundle 'DeveloperBasePackages' -BucketPath $PSScriptRoot
}

Describe 'DeveloperBasePackages bundle (declarative)' -Tag 'Light','Bundle' {

    It 'declares Node.js via choco' {
        $node = $script:pkgs | Where-Object Name -eq 'Node.js'
        $node.Installer    | Should -Be 'choco'
        $node.Id           | Should -Be 'nodejs'
        $node.CliCommands  | Should -Contain 'node'
    }

    It 'declares dotnet, Visual Studio, Beyond Compare via scoop -g' {
        foreach ($name in 'dotnet','Visual Studio','Beyond Compare') {
            $p = $script:pkgs | Where-Object Name -eq $name
            $p           | Should -Not -BeNullOrEmpty
            $p.Installer | Should -Be 'scoop'
            $p.Scope     | Should -Be 'global'
        }
    }

    It 'declares Beyond Compare with a PostInstallScript for the bcomp shim swap' {
        $bc = $script:pkgs | Where-Object Name -eq 'Beyond Compare'
        $bc.Id                     | Should -Be 'extras/beyondcompare'
        $bc.HasPostInstallScript   | Should -BeTrue
    }

    It 'declares VS Code, GitHub Copilot CLI, and Python via winget' {
        foreach ($name in 'Visual Studio Code','GitHub Copilot CLI','Python') {
            $p = $script:pkgs | Where-Object Name -eq $name
            $p.Installer | Should -Be 'winget'
        }
    }

    It 'sets Completion=pscompletions for the GitHub Copilot CLI (no native PS completion)' {
        $cop = $script:pkgs | Where-Object Name -eq 'GitHub Copilot CLI'
        $cop.Completion | Should -Be 'pscompletions'
    }

    It 'declares Aspire via the MarkMichaelis scoop bucket with DependsOn dotnet+VS' {
        $aspire = $script:pkgs | Where-Object Name -eq 'Aspire'
        $aspire.Installer  | Should -Be 'scoop'
        $aspire.Id         | Should -Be 'MarkMichaelis/Aspire'
        $aspire.DependsOn  | Should -Contain 'dotnet'
        $aspire.DependsOn  | Should -Contain 'Visual Studio'
    }
}
