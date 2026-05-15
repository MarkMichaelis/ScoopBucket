$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

$sut  = (Split-Path -Leaf $PSCommandPath).Replace('.Tests.ps1', '')
$name = $sut

Describe "Install $name" -Tag 'Manual','Heavy','Install' {
    BeforeAll {
        if (Test-ScoopPackageInstalled $name) {
            # Don't auto-uninstall heavyweight packages — uninstalling a WSL
            # distro is destructive. If already installed, skip the install
            # path; the idempotency check below still validates re-run.
            $script:preInstalled = $true
        } else {
            $script:preInstalled = $false
        }
    }

    It 'installs from the local manifest' -Skip:$script:preInstalled {
        Install-LocalManifest "$PSScriptRoot\$name.json"
        Test-ScoopPackageInstalled $name | Should -Be $true
    }

    It 'is idempotent on re-run' {
        { Install-LocalManifest "$PSScriptRoot\$name.json" } | Should -Not -Throw
        Test-ScoopPackageInstalled $name | Should -Be $true
    }

    It 'is registered as a WSL distro' {
        # `wsl --list --quiet` emits UTF-16; pipe through Out-String so -match
        # operates on a single normalized string.
        $distros = (& wsl.exe --list --quiet 2>$null) | Out-String
        ($distros -match 'Ubuntu-18\.04') | Should -Not -BeNullOrEmpty
    }
}
