. "$PSScriptRoot\Utils.ps1"

$sut  = (Split-Path -Leaf $PSCommandPath).Replace('.Tests.ps1', '')
$name = $sut

# The MicrosoftCopilot manifest is a no-op: it only emits a Write-Warning
# noting that the consumer Copilot desktop app is built into Windows 11.
# There is no external app to verify, so the post-install assertion is
# limited to the scoop bookkeeping itself.
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
}
