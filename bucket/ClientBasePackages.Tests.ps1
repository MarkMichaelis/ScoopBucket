#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Behavior-first tests for the Todoist desktop entry in ClientBasePackages.

    The sachaos/todoist CLI companion (winget 'Sachaos.Todoist') was removed
    in #326 because the package was delisted from winget upstream -- confirmed
    on a clean CI runner in #325 (winget search/show/install all return
    -1978335212 "No package found"). The guards below lock in that removal:
    re-adding the dead CLI entry or its companion link fails them.
#>

BeforeAll {
    $scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
    if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }
    $script:pkgs = @(Get-Package -BucketPath $PSScriptRoot)
}

Describe 'ClientBasePackages: Todoist desktop entry' -Tag 'Light','Bundle' {

    It 'declares the existing Todoist desktop entry (regression guard)' {
        $desktop = @($script:pkgs | Where-Object Name -EQ 'Todoist')
        $desktop.Count        | Should -Be 1
        $desktop[0].Installer | Should -Be 'winget'
        $desktop[0].Id        | Should -Be '9MWF2DWS5Z9N'
        $desktop[0].Source    | Should -Be 'msstore'
        $desktop[0].Bundle    | Should -Be 'ClientBasePackages'
    }

    It 'no longer declares a Todoist CLI package (Sachaos.Todoist delisted from winget, #326)' {
        @($script:pkgs | Where-Object Name -EQ 'Todoist CLI').Count | Should -Be 0
        @($script:pkgs | Where-Object Id -EQ 'Sachaos.Todoist').Count | Should -Be 0
    }

    It 'Todoist desktop no longer lists a Todoist CLI companion (#326)' {
        $desktop = @($script:pkgs | Where-Object Name -EQ 'Todoist')[0]
        @($desktop.Companions) | Should -Not -Contain 'Todoist CLI'
    }

    It 'Bitwarden desktop declares Companions=@(Bitwarden CLI) (auto-install CLI with app)' {
        $desktop = @($script:pkgs | Where-Object Name -EQ 'Bitwarden')[0]
        @($desktop.Companions) | Should -Contain 'Bitwarden CLI'
    }
}

Describe 'ClientBasePackages: Amazon Kindle Store migration (#394)' -Tag 'Light','Bundle' {

    It 'declares Kindle as the Microsoft Store package' {
        $kindle = @($script:pkgs | Where-Object Name -EQ 'Amazon Kindle')
        $kindle.Count        | Should -Be 1
        $kindle[0].Installer | Should -Be 'winget'
        $kindle[0].Id        | Should -Be '9P8JQ0JJSTLL'
        $kindle[0].Source    | Should -Be 'msstore'
        $kindle[0].Bundle    | Should -Be 'ClientBasePackages'
    }

    It 'no longer declares the legacy Kindle for PC package (discontinued 2026-06-30)' {
        # Amazon.Kindle still resolves in the winget default source and its
        # installer URL is still live, so a regression here would install
        # silently and pass CI while placing dead software on the machine.
        @($script:pkgs | Where-Object Id -EQ 'Amazon.Kindle').Count | Should -Be 0
    }

    It 'records why the Kindle version cannot be pinned' {
        $kindle = @($script:pkgs | Where-Object Name -EQ 'Amazon Kindle')[0]
        $kindle.Notes | Should -Match 'Epubor'
    }
}

Describe 'ClientBasePackages: Epubor manifest (#394)' -Tag 'Light','Bundle' {

    BeforeAll {
        $script:epuborPath = Join-Path $PSScriptRoot 'client\Epubor.json'
        $script:epubor     = Get-Content -Raw -Path $script:epuborPath | ConvertFrom-Json
    }

    It 'declares a real upstream version rather than the 1.00.001 placeholder' {
        $script:epubor.version | Should -Not -Be '1.00.001'
        $script:epubor.version | Should -Match '^\d+\.\d+\.\d+\.\d+$'
    }

    It 'still downloads from the floating latest URL' {
        # Epubor publishes versioned URLs only for select archived builds, so
        # the floating URL stays the install source and `version` is a record
        # of what latest was when the manifest was last refreshed.
        @($script:epubor.url) | Should -Contain 'https://download.epubor.com/epubor_ultimate.exe'
    }
}
