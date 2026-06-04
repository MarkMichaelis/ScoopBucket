$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

$sut  = (Split-Path -Leaf $PSCommandPath).Replace('.Tests.ps1', '')
$name = $sut

Describe "Install $name" -Tag 'Heavy', 'Install', 'Manual' {
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

    It 'has Windows PowerShell 5.1 available in System32' {
        # The manifest runs `choco install PowerShell` which is a no-op on a
        # normal Windows host. Assert the in-box Windows PowerShell binary
        # exists rather than trying to resolve `powershell` on PATH.
        Test-Path "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" | Should -Be $true
    }
}
