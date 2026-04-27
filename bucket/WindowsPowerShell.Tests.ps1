. "$PSScriptRoot\Utils.ps1"

$sut  = (Split-Path -Leaf $PSCommandPath).Replace('.Tests.ps1', '')
$name = $sut

Describe "Install $name" -Tag 'Heavy', 'Install' {
    BeforeAll {
        if (Test-ScoopPackageInstalled $name) { scoop uninstall $name }
    }

    It 'installs from the local manifest' {
        Install-LocalManifest "$PSScriptRoot\$name.json"
        Test-ScoopPackageInstalled $name | Should -Be $true
    }

    It 'is idempotent on re-run' {
        { Install-LocalManifest "$PSScriptRoot\$name.json" } | Should -Not -Throw
        Test-ScoopPackageInstalled $name | Should -Be $true
    }

    It 'is reported as installed by scoop' {
        # This manifest depends on PowerShellWindows and runs
        # SetPowerConfiguration.ps1; it does not put a new CLI on PATH, so the
        # primary signal is simply that scoop reports the package as installed.
        Test-ScoopPackageInstalled $name | Should -Be $true
    }
}
