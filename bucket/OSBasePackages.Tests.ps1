<#
.SYNOPSIS
    Light-suite tests for the migrated (declarative) OSBasePackages.ps1.

.DESCRIPTION
    Asserts the bundle exposes the expected [Package[]] collection via
    Get-Package (Bundle='OSBasePackages'). The collection is captured in
    a child runspace by Get-BundlePackages so no engines actually run.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Utils.ps1')
    Import-Module (Get-ScoopBucketModulePath) -Force
    $script:pkgs = Get-Package -Bundle 'OSBasePackages' -BucketPath $PSScriptRoot
}

Describe 'OSBasePackages bundle (declarative)' -Tag 'Light','Bundle' {

    It 'declares at least one package' {
        @($script:pkgs).Count | Should -BeGreaterThan 0
    }

    It 'includes ripgrep with scoop main/ripgrep and native completion' {
        $rg = $script:pkgs | Where-Object Name -eq 'ripgrep'
        $rg                 | Should -Not -BeNullOrEmpty
        $rg.Installer       | Should -Be 'scoop'
        $rg.Id              | Should -Be 'main/ripgrep'
        $rg.CliCommands     | Should -Contain 'rg'
        $rg.Completion      | Should -Be 'native'
    }

    It 'includes ffmpeg via scoop main' {
        $ffmpeg = $script:pkgs | Where-Object Name -eq 'ffmpeg'
        $ffmpeg.Installer | Should -Be 'scoop'
        $ffmpeg.Id        | Should -Be 'main/ffmpeg'
    }

    It 'includes the Sysinternals Suite via scoop extras' {
        $si = $script:pkgs | Where-Object Name -eq 'Sysinternals Suite'
        $si.Installer | Should -Be 'scoop'
        $si.Id        | Should -Be 'extras/sysinternals'
    }

    It 'declares the legacy winget core OS packages' {
        $names = $script:pkgs.Name
        foreach ($expected in 'Windows Terminal', '7-Zip', 'Everything', 'Everything CLI',
                              'Google Chrome', 'WinDirStat', 'bat', 'fzf', 'Google Cloud SDK') {
            $names | Should -Contain $expected
        }
    }

    It 'sets Completion=pscompletions for Google Cloud SDK (gcloud)' {
        $gcloud = $script:pkgs | Where-Object Name -eq 'Google Cloud SDK'
        $gcloud.Completion | Should -Be 'pscompletions'
    }
}
