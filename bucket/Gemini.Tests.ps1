. "$PSScriptRoot\Utils.ps1"

$sut  = (Split-Path -Leaf $PSCommandPath).Replace('.Tests.ps1', '')
$name = $sut

# Tagged 'Manual' because Gemini.ps1 uses a browser-watch pattern: it opens
# the Google app desktop download page and waits for the user to click
# "Download app". This cannot run unattended in CI.
Describe "Install $name" -Tag 'Manual', 'Heavy', 'Install' {
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
        Test-Path (Join-Path $env:LOCALAPPDATA 'Google\GoogleApp') | Should -Be $true
    }
}
