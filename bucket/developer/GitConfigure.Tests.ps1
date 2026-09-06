$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

$sut  = (Split-Path -Leaf $PSCommandPath).Replace('.Tests.ps1', '')
$name = $sut

Describe "Install $name" -Tag 'Heavy', 'Install', 'Manual' {
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

    It 'sets push.default to simple' {
        git config --global push.default | Should -Be 'simple'
    }

    It 'sets core.autocrlf to input so CRLF never enters the index' {
        # `input`, not `true`: `true` would also rewrite the working tree to
        # CRLF and break shell scripts under WSL, Docker and Linux CI.
        git config --global core.autocrlf | Should -Be 'input'
    }
}
