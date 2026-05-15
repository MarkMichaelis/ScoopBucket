$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

$sut  = (Split-Path -Leaf $PSCommandPath).Replace('.Tests.ps1', '')
$name = $sut

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

    It 'configures the bc difftool when Beyond Compare is installed' {
        . "$PSScriptRoot\GitConfigBeyondCompare.ps1" *>$null
        $bcDir = Resolve-BeyondCompareDir
        if (-not $bcDir) {
            Set-ItResult -Skipped -Because 'Beyond Compare not installed'
            return
        }
        git config --global diff.tool | Should -Be 'bc'
    }

    It 'discovers a registry-recorded Beyond Compare install when present' {
        . "$PSScriptRoot\GitConfigBeyondCompare.ps1" *>$null
        $regDir = Get-BeyondCompareDirFromRegistry
        $anyKey = (Test-Path 'HKCU:\SOFTWARE\Scooter Software') -or
                  (Test-Path 'HKLM:\SOFTWARE\Scooter Software') -or
                  (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Scooter Software')
        if (-not $anyKey) {
            Set-ItResult -Skipped -Because 'No Scooter Software registry keys on this machine'
            return
        }
        if (-not $regDir) {
            Set-ItResult -Skipped -Because 'Scooter Software key exists but no usable BComp.exe was found via registry probe'
            return
        }
        Test-Path (Join-Path $regDir 'BComp.exe') | Should -Be $true
    }
}
