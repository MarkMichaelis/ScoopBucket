. "$PSScriptRoot\Utils.ps1"

$sut  = (Split-Path -Leaf $PSCommandPath).Replace('.Tests.ps1', '')
$name = $sut

Describe "Install $name" -Tag 'Heavy', 'Install' {
    BeforeAll {
        if (Test-ScoopPackageInstalled $name) {
            scoop uninstall $name
        }
    }

    It 'runs the uninstaller without throwing' {
        { Install-LocalManifest "$PSScriptRoot\$name.json" } | Should -Not -Throw
    }

    It 'is idempotent on re-run' {
        { Install-LocalManifest "$PSScriptRoot\$name.json" } | Should -Not -Throw
    }

    It 'leaves no McAfee programs registered' {
        Get-Program 'McAfee*' | Should -BeNullOrEmpty
    }
}
