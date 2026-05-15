$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\ScoopBucket\ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module ScoopBucket -Force }

$sut  = (Split-Path -Leaf $PSCommandPath).Replace('.Tests.ps1', '')
$name = $sut

# Gemini.ps1 now performs a fully automated install via direct download from
# dl.google.com (the URL is constructed using the appguid/path constants
# extracted from search.google's main.min.js). Falls back to the legacy
# browser-watch pattern only if that direct fetch fails. Tagged 'Heavy'
# because it actually downloads ~11 MB and runs the Omaha installer.
Describe "Install $name" -Tag 'Heavy', 'Install' {
    BeforeAll {
        if (Test-ScoopPackageInstalled $name) {
            scoop uninstall $name
        }
    }

    It 'installs from the local manifest' {
        Install-LocalManifest "$PSScriptRoot\$name.json"
        Test-ScoopPackageInstalled $name | Should -Be $true
    }

    It 'is idempotent on re-run' {
        { Install-LocalManifest "$PSScriptRoot\$name.json" } | Should -Not -Throw
        Test-ScoopPackageInstalled $name | Should -Be $true
    }

    It 'drops the Google app for desktop install marker' {
        Test-Path (Join-Path $env:LOCALAPPDATA 'Google\Google\latest\google.exe') | Should -Be $true
    }
}
