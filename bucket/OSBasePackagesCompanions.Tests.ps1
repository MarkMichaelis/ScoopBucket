#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Bundle audit for OSBasePackages Companions cascade:
    Everything desktop must pull in Everything CLI when installed.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
    $script:osPkgs = @(Get-Package -BucketPath $PSScriptRoot -Bundle 'OSBasePackages')
}

Describe 'OSBasePackages: Everything desktop -> Everything CLI Companions' -Tag 'Light','Bundle' {
    It 'Everything desktop declares Companions=@(Everything CLI)' {
        $desktop = @($script:osPkgs | Where-Object Name -EQ 'Everything')[0]
        $desktop                       | Should -Not -BeNullOrEmpty
        @($desktop.Companions)         | Should -Contain 'Everything CLI'
    }

    It 'Everything CLI exists in the same bundle (round-trip sanity)' {
        $cli = @($script:osPkgs | Where-Object Name -EQ 'Everything CLI')
        $cli.Count | Should -Be 1
    }
}
