<#
.SYNOPSIS
    Light tests for the migrated (declarative) ClientBasePackages.ps1.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Utils.ps1')
    Import-Module (Get-ScoopBucketModulePath) -Force
    $script:pkgs = Get-Package -Bundle 'ClientBasePackages' -BucketPath $PSScriptRoot
}

Describe 'ClientBasePackages bundle (declarative)' -Tag 'Light','Bundle' {

    It 'declares the two choco packages (exiftool, GeoSetter)' {
        $names = ($script:pkgs | Where-Object Installer -eq 'choco').Name
        $names | Should -Contain 'exiftool'
        $names | Should -Contain 'GeoSetter'
    }

    It 'declares MarkMichaelis/DbxCli, ClaudeExcel, and AIAgents bundle via scoop' {
        $scoopIds = ($script:pkgs | Where-Object Installer -eq 'scoop').Id
        $scoopIds | Should -Contain 'MarkMichaelis/DbxCli'
        $scoopIds | Should -Contain 'MarkMichaelis/ClaudeExcel'
        $scoopIds | Should -Contain 'MarkMichaelis/AIAgents'
    }

    It 'declares 5 global scoop extras (claude, espeak-ng, notion, spotify, zoom)' {
        $globals = $script:pkgs | Where-Object { $_.Installer -eq 'scoop' -and $_.Scope -eq 'global' }
        @($globals).Count | Should -Be 5
        foreach ($id in 'extras/claude','main/espeak-ng','extras/notion','extras/spotify','extras/zoom') {
            $globals.Id | Should -Contain $id
        }
    }

    It 'declares msstore packages with Source=msstore' {
        $msstore = $script:pkgs | Where-Object Source -eq 'msstore'
        @($msstore).Count | Should -Be 6
        $msstore.Id | Should -Contain '9NT1R1C2HH7J'   # ChatGPT
        $msstore.Id | Should -Contain '9NKSQGP7F2NH'   # WhatsApp
        $msstore.Id | Should -Contain 'XPDNSF6TXN2R6Z' # Snagit
    }

    It 'sets CISkip for Pushbullet' {
        $pb = $script:pkgs | Where-Object Name -eq 'Pushbullet'
        $pb.CISkip | Should -Not -BeNullOrEmpty
    }

    It 'declares Bitwarden CLI with PSCompletions and DependsOn Bitwarden' {
        $bw = $script:pkgs | Where-Object Name -eq 'Bitwarden CLI'
        $bw.Completion | Should -Be 'pscompletions'
        $bw.DependsOn  | Should -Contain 'Bitwarden'
    }

    It 'declares Readwise Reader as a custom sideloaded MSIX install' {
        $rw = $script:pkgs | Where-Object Name -eq 'Readwise Reader'
        $rw.Installer              | Should -Be 'custom'
        $rw.HasCustomInstallScript | Should -BeTrue
        $rw.HasVerifyScript        | Should -BeTrue
    }
}
